#!/bin/bash
set -e

# LLVM Documentation Build Script
# Builds all LLVM subproject documentation with Sphinx

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# Configuration
SITE_DIR="${SITE_DIR:-_site}"
BUILD_DIR="_build"

# Project categories
STRICT_PROJECTS=("llvm" "clang" "libc" "clang-tools-extra" "libcxx")
RELAXED_PROJECTS=("lld" "flang" "polly" "openmp" "bolt" "libunwind" "offload" "lldb")
DOXYGEN_PROJECTS=("mlir")

ALL_PROJECTS=("${STRICT_PROJECTS[@]}" "${RELAXED_PROJECTS[@]}")

# Counters
SUCCESS_COUNT=0
FAILURE_COUNT=0
FAILED_PROJECTS=()

echo -e "${BLUE} LLVM Documentation Builder${NC}"
echo -e "${BLUE}============================${NC}"

mkdir -p "$SITE_DIR"

# Build function
build_project() {
    local project="$1"
    local is_strict="$2"
    
    [[ ! -d "$project/docs" ]] && {
        echo -e "${YELLOW}⚠️  Skipping $project: docs directory not found${NC}"
        return 0
    }
    
    # Skip Doxygen projects
    for doxy_project in "${DOXYGEN_PROJECTS[@]}"; do
        [[ "$project" == "$doxy_project" ]] && {
            echo -e "${YELLOW}⚠️  Skipping $project: Doxygen-only project${NC}"
            return 0
        }
    done
    
    echo -e "${BLUE}📖 Building $project documentation...${NC}"
    
    cd "$project/docs" || {
        echo -e "${RED}❌ Failed to enter $project/docs directory${NC}"
        FAILED_PROJECTS+=("$project")
        ((FAILURE_COUNT++))
        return 1
    }
    
    mkdir -p "_static"
    rm -rf "$BUILD_DIR"
    
    local build_cmd="sphinx-build -b html"
    [[ "$is_strict" == "true" ]] && build_cmd="$build_cmd -W --keep-going"
    build_cmd="$build_cmd . $BUILD_DIR/html"
    
    if timeout 600 bash -c "eval '$build_cmd' 2>&1 | tee '../../build-$project.log'"; then
        if [[ -d "$BUILD_DIR/html" ]] && [[ -n "$(ls -A $BUILD_DIR/html 2>/dev/null)" ]]; then
            mkdir -p "../../$SITE_DIR/$project"
            if cp -r "$BUILD_DIR/html/"* "../../$SITE_DIR/$project/" 2>/dev/null; then
                echo -e "${GREEN}✅ $project documentation built successfully${NC}"
                ((SUCCESS_COUNT++))
            else
                echo -e "${RED}❌ Failed to copy $project documentation${NC}"
                FAILED_PROJECTS+=("$project")
                ((FAILURE_COUNT++))
            fi
        else
            echo -e "${RED}❌ $project build completed but no output found${NC}"
            FAILED_PROJECTS+=("$project")
            ((FAILURE_COUNT++))
        fi
    else
        echo -e "${RED}❌ Failed to build $project documentation (timeout or error)${NC}"
        FAILED_PROJECTS+=("$project")
        ((FAILURE_COUNT++))
    fi
    
    cd - > /dev/null
}

# Build projects
echo -e "${YELLOW}Building projects with strict warning handling...${NC}"
for project in "${STRICT_PROJECTS[@]}"; do
    build_project "$project" "true"
done

echo -e "\n${YELLOW}Building projects with relaxed warning handling...${NC}"
for project in "${RELAXED_PROJECTS[@]}"; do
    build_project "$project" "false"
done

# Summary
echo -e "\n${BLUE}📊 Build Summary${NC}"
echo -e "${BLUE}================${NC}"
echo -e "Total projects: ${#ALL_PROJECTS[@]}"
echo -e "${GREEN}Successful builds: $SUCCESS_COUNT${NC}"
echo -e "${RED}Failed builds: $FAILURE_COUNT${NC}"

[[ ${#FAILED_PROJECTS[@]} -gt 0 ]] && echo -e "${RED}Failed projects: ${FAILED_PROJECTS[*]}${NC}"

echo -e "\n${BLUE}📁 Output directory: $SITE_DIR${NC}"
echo -e "${BLUE}📋 Build logs: build-*.log${NC}"

if [[ $FAILURE_COUNT -gt 0 ]]; then
    echo -e "${RED}❌ Some documentation builds failed. Check the logs for details.${NC}"
    exit 1
else
    echo -e "${GREEN}🎉 All documentation built successfully!${NC}"
fi
