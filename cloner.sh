#!/bin/bash

# Java Repository Clone and Validation Script
# This script searches for, clones, and validates Java 8 Maven repositories with JUnit 5

#set -e  # Exit on any error

# Configuration
GITHUB_TOKEN="${GITHUB_TOKEN:-}"  # Set your GitHub token as environment variable
CLONE_DIR="./cloned_repos"
LOG_FILE="./repo_validation.log"
MAX_REPOS=500  # Maximum number of repositories to process
MAX_PAGES=50  # Number of pages to fetch from GitHub
JAVA_VERSION="1.8"  # Target Java version

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Logging function
log() {
    local level=$1
    shift
    local message="$@"
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    echo -e "${timestamp} [${level}] ${message}" | tee -a "$LOG_FILE"
}

# Check prerequisites
check_prerequisites() {
    log "INFO" "${BLUE}Checking prerequisites...${NC}"
    
    # Check if required tools are installed
    local required_tools=("git" "mvn" "java" "javac" "curl" "jq")
    for tool in "${required_tools[@]}"; do
        if ! command -v "$tool" &> /dev/null; then
            log "ERROR" "${RED}$tool is not installed or not in PATH${NC}"
            exit 1
        fi
    done
    
    # Check Java version
    local java_version=$(java -version 2>&1 | grep -o '"[0-9]\+\.[0-9]\+' | cut -d'"' -f2)
    log "INFO" "Java version detected: $java_version"
    
    # Check Maven version
    local maven_version=$(mvn -version 2>&1 | head -n1 | cut -d' ' -f3)
    log "INFO" "Maven version detected: $maven_version"
    
    # Create clone directory
    mkdir -p "$CLONE_DIR"
    
    log "INFO" "${GREEN}Prerequisites check passed${NC}"
}

# Search for repositories on GitHub
search_repositories() {
    log "INFO" "${BLUE}Searching for Java 8 Maven repositories with JUnit 5 (fetching ${MAX_PAGES} pages)...${NC}"
    
    local auth_header=""
    if [[ -n "$GITHUB_TOKEN" ]]; then
        auth_header="Authorization: token $GITHUB_TOKEN"
    fi
    
    # GitHub API search query for Java repositories with specific criteria
    local query="language:java+maven+junit5+java8+in:readme,description"
    local api_url="https://api.github.com/search/repositories"
    
    # Clear or create temporary file
    > repo_urls.tmp
    
    local total_repos_found=0
    
    # Fetch multiple pages
    for page in $(seq 1 $MAX_PAGES); do
        log "INFO" "Fetching page $page of $MAX_PAGES..."
        
        local params="q=${query}&sort=stars&order=desc&per_page=100&page=${page}"
        local response=$(curl -s -H "$auth_header" "${api_url}?${params}")
        
        if [[ $? -ne 0 ]]; then
            log "ERROR" "${RED}Failed to fetch page $page${NC}"
            continue
        fi
        
        # Check for API rate limit
        local rate_limit_remaining=$(echo "$response" | jq -r '.message // empty' | grep -i "rate limit" || echo "")
        if [[ -n "$rate_limit_remaining" ]]; then
            log "WARN" "${YELLOW}GitHub API rate limit reached at page $page${NC}"
            break
        fi
        
        # Extract repository clone URLs from this page
        local page_repos=$(echo "$response" | jq -r '.items[]? | .clone_url')
        
        # Check if we got any results
        if [[ -z "$page_repos" ]]; then
            log "INFO" "No more repositories found at page $page, stopping pagination"
            break
        fi
        
        # Append to temporary file
        echo "$page_repos" >> repo_urls.tmp
        
        local repos_this_page=$(echo "$page_repos" | wc -l)
        total_repos_found=$((total_repos_found + repos_this_page))
        
        log "INFO" "Found $repos_this_page repositories on page $page (total: $total_repos_found)"
        
        # Check if we've reached the maximum
        if [[ $total_repos_found -ge $MAX_REPOS ]]; then
            log "INFO" "Reached maximum repository limit ($MAX_REPOS)"
            break
        fi
        
        # Be nice to GitHub API - add a small delay between requests
        sleep 1
    done
    
    # Limit to MAX_REPOS if we got more
    if [[ $total_repos_found -gt $MAX_REPOS ]]; then
        head -n $MAX_REPOS repo_urls.tmp > repo_urls.tmp.limited
        mv repo_urls.tmp.limited repo_urls.tmp
        total_repos_found=$MAX_REPOS
    fi
    
    log "INFO" "Total of $total_repos_found repositories to process"
    
    if [[ $total_repos_found -eq 0 ]]; then
        log "WARN" "${YELLOW}No repositories found matching criteria${NC}"
        rm -f repo_urls.tmp
        exit 0
    fi
}

# Clone a repository
clone_repository() {
    local repo_url=$1
    local repo_name=$(basename "$repo_url" .git)
    local clone_path="$CLONE_DIR/$repo_name"
    
    log "INFO" "Cloning: $repo_url"
    
    if [[ -d "$clone_path" ]]; then
        log "WARN" "Repository $repo_name already exists, skipping clone"
        return 0
    fi
    
    if git clone --depth 1 "$repo_url" "$clone_path" &>/dev/null; then
        log "INFO" "${GREEN}Successfully cloned: $repo_name${NC}"
        return 0
    else
        log "ERROR" "${RED}Failed to clone: $repo_name${NC}"
        return 1
    fi
}

# Check if repository meets our criteria
validate_repository_structure() {
    local repo_path=$1
    local repo_name=$(basename "$repo_path")
    
    log "INFO" "Validating repository structure: $repo_name"
    
    # Check for pom.xml (Maven project)
    if [[ ! -f "$repo_path/pom.xml" ]]; then
        log "WARN" "No pom.xml found in $repo_name"
        return 1
    fi
    
    # Check Java version in pom.xml
    local java_version_in_pom=$(grep -E "(java\.version|maven\.compiler\.(source|target))" "$repo_path/pom.xml" | head -1 | grep -o '[0-9]\+\.[0-9]\+\|[0-9]\+' | head -1)
    
    if [[ -n "$java_version_in_pom" && "$java_version_in_pom" != "1.8" && "$java_version_in_pom" != "8" ]]; then
        log "WARN" "Repository $repo_name uses Java $java_version_in_pom, not Java 8"
        return 1
    fi
    
    # Check for JUnit 5 dependency
    if ! grep -q "junit-jupiter" "$repo_path/pom.xml"; then
        log "WARN" "No JUnit 5 (jupiter) dependency found in $repo_name"
        return 1
    fi
    
    # Check for test directory
    if [[ ! -d "$repo_path/src/test/java" ]]; then
        log "WARN" "No test directory found in $repo_name"
        return 1
    fi
    
    # Check for actual test files
    local test_count=$(find "$repo_path/src/test/java" -name "*.java" -type f | wc -l)
    if [[ $test_count -eq 0 ]]; then
        log "WARN" "No test files found in $repo_name"
        return 1
    fi
    
    log "INFO" "${GREEN}Repository structure validation passed for $repo_name${NC}"
    return 0
}

# Compile the repository
compile_repository() {
    local repo_path=$1
    local repo_name=$(basename "$repo_path")
    
    log "INFO" "Compiling repository: $repo_name"
    
    cd "$repo_path"
    
    # Clean and compile
    if mvn clean compile -q -Dmaven.test.skip=true &>/dev/null; then
        log "INFO" "${GREEN}Compilation successful for $repo_name${NC}"
        cd - &>/dev/null
        return 0
    else
        log "ERROR" "${RED}Compilation failed for $repo_name${NC}"
        cd - &>/dev/null
        return 1
    fi
}

# Run unit tests
run_tests() {
    local repo_path=$1
    local repo_name=$(basename "$repo_path")
    
    log "INFO" "Running tests for repository: $repo_name"
    
    cd "$repo_path"
    
    # Run tests with timeout
    if timeout 300 mvn test -q &>/dev/null; then
        log "INFO" "${GREEN}Tests passed for $repo_name${NC}"
        cd - &>/dev/null
        return 0
    else
        log "ERROR" "${RED}Tests failed or timed out for $repo_name${NC}"
        cd - &>/dev/null
        return 1
    fi
}

# Remove failed repository
remove_repository() {
    local repo_path=$1
    local repo_name=$(basename "$repo_path")
    
    log "INFO" "${YELLOW}Removing failed repository: $repo_name${NC}"
    rm -rf "$repo_path"
}

# Process a single repository
process_repository() {
    local repo_url=$1
    local repo_name=$(basename "$repo_url" .git)
    local repo_path="$CLONE_DIR/$repo_name"
    
    log "INFO" "${BLUE}Processing repository: $repo_name${NC}"
    
    # Clone repository
    if ! clone_repository "$repo_url"; then
        return 1
    fi
    
    # Validate structure
    if ! validate_repository_structure "$repo_path"; then
        remove_repository "$repo_path"
        return 1
    fi
    
    # Compile repository
    if ! compile_repository "$repo_path"; then
        remove_repository "$repo_path"
        return 1
    fi
    
    # Run tests
    if ! run_tests "$repo_path"; then
        remove_repository "$repo_path"
        return 1
    fi
    
    log "INFO" "${GREEN}Repository $repo_name successfully validated and kept${NC}"
    return 0
}

# Generate summary report
generate_report() {
    log "INFO" "${BLUE}Generating summary report...${NC}"
    
    local total_repos=$(wc -l < repo_urls.tmp 2>/dev/null || echo "0")
    local successful_repos=$(find "$CLONE_DIR" -maxdepth 1 -type d | grep -v "^$CLONE_DIR$" | wc -l)
    local failed_repos=$((total_repos - successful_repos))
    
    echo ""
    echo "=================================="
    echo "REPOSITORY VALIDATION SUMMARY"
    echo "=================================="
    echo "Total repositories processed: $total_repos"
    echo "Successfully validated: $successful_repos"
    echo "Failed validation (removed): $failed_repos"
    
    if [[ $total_repos -gt 0 ]]; then
        echo "Success rate: $(awk "BEGIN {printf \"%.1f\", $successful_repos*100/$total_repos}")%"
    else
        echo "Success rate: 0.0%"
    fi
    echo ""
    echo "Validated repositories are stored in: $CLONE_DIR"
    echo "Full log available at: $LOG_FILE"
    echo "=================================="
}

# Cleanup function
cleanup() {
    rm -f repo_urls.tmp
    log "INFO" "Cleanup completed"
}

# Main execution
main() {
    log "INFO" "${BLUE}Starting Java Repository Clone and Validation Script${NC}"
    
    # Set up cleanup trap
    trap cleanup EXIT
    
    # Check prerequisites
    check_prerequisites
    
    # Search for repositories
    search_repositories
    
    # Process each repository
    local successful=0
    local failed=0
    
    while IFS= read -r repo_url; do
        if [[ -n "$repo_url" ]]; then
            if process_repository "$repo_url"; then
                ((successful++))
            else
                ((failed++))
            fi
        fi
    done < repo_urls.tmp
    
    # Generate final report
    generate_report
    
    log "INFO" "${GREEN}Script execution completed${NC}"
}

# Print usage information
usage() {
    echo "Usage: $0 [options]"
    echo ""
    echo "Options:"
    echo "  -h, --help          Show this help message"
    echo "  -t, --token TOKEN   Set GitHub API token"
    echo "  -d, --dir DIR       Set clone directory (default: ./cloned_repos)"
    echo "  -m, --max NUM       Set maximum repositories to process (default: 500)"
    echo "  -p, --pages NUM     Set number of pages to fetch (default: 50)"
    echo ""
    echo "Environment variables:"
    echo "  GITHUB_TOKEN        GitHub API token for authenticated requests"
    echo ""
    echo "Examples:"
    echo "  $0                  # Run with default settings"
    echo "  $0 -t your_token    # Run with GitHub token"
    echo "  $0 -d /tmp/repos    # Use custom clone directory"
    echo "  $0 -m 20            # Process maximum 20 repositories"
    echo "  $0 -p 10            # Fetch only 10 pages from GitHub"
}

# Parse command line arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        -h|--help)
            usage
            exit 0
            ;;
        -t|--token)
            GITHUB_TOKEN="$2"
            shift 2
            ;;
        -d|--dir)
            CLONE_DIR="$2"
            shift 2
            ;;
        -m|--max)
            MAX_REPOS="$2"
            shift 2
            ;;
        -p|--pages)
            MAX_PAGES="$2"
            shift 2
            ;;
        *)
            log "ERROR" "Unknown option: $1"
            usage
            exit 1
            ;;
    esac
done

# Run main function
main
