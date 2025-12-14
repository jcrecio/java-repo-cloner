#!/bin/bash

# Java Repository Clone and Validation Script
# This script searches for, clones, and validates Java 8 Maven repositories with JUnit 5

set -e  # Exit on any error

# Configuration
GITHUB_TOKEN="${GITHUB_TOKEN:-}"  # Set your GitHub token as environment variable
CLONE_DIR="./cloned_repos"
LOG_FILE="./repo_validation.log"
PENDING_LIST="./pending_repos.txt"
VALIDATED_LIST="./validated_repos.txt"
MAX_REPOS=50  # Maximum number of repositories to process
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
    
    # Initialize validated repos list if it doesn't exist
    if [[ ! -f "$VALIDATED_LIST" ]]; then
        echo "# Validated Java 8 Maven Repositories with JUnit 5" > "$VALIDATED_LIST"
        echo "# Format: Repository Name | Repository URL" >> "$VALIDATED_LIST"
        echo "# =============================================" >> "$VALIDATED_LIST"
    fi
    
    log "INFO" "${GREEN}Prerequisites check passed${NC}"
}

# Search for repositories on GitHub
search_repositories() {
    log "INFO" "${BLUE}Searching for Java 8 Maven repositories with JUnit 5...${NC}"
    
    local auth_header=""
    if [[ -n "$GITHUB_TOKEN" ]]; then
        auth_header="Authorization: token $GITHUB_TOKEN"
    fi
    
    # GitHub API search query for Java repositories with specific criteria
    local query="language:java+maven+junit5+java8+in:readme,description"
    local api_url="https://api.github.com/search/repositories"
    local params="q=${query}&sort=stars&order=desc&per_page=${MAX_REPOS}"
    
    local response=$(curl -s -H "$auth_header" "${api_url}?${params}")
    
    if [[ $? -ne 0 ]]; then
        log "ERROR" "${RED}Failed to search repositories${NC}"
        exit 1
    fi
    
    # Extract repository information (name and clone URL)
    echo "$response" | jq -r '.items[]? | "\(.name)|\(.clone_url)"' > "$PENDING_LIST"
    
    local repo_count=$(wc -l < "$PENDING_LIST" 2>/dev/null || echo "0")
    log "INFO" "Found $repo_count repositories to process"
    log "INFO" "Pending repositories saved to: $PENDING_LIST"
    
    if [[ $repo_count -eq 0 ]]; then
        log "WARN" "${YELLOW}No repositories found matching criteria${NC}"
        rm -f "$PENDING_LIST"
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

# Add repository to validated list
add_to_validated_list() {
    local repo_name=$1
    local repo_url=$2
    
    echo "$repo_name | $repo_url" >> "$VALIDATED_LIST"
    log "INFO" "${GREEN}Added $repo_name to validated list${NC}"
}

# Remove repository from pending list
remove_from_pending_list() {
    local repo_name=$1
    local repo_url=$2
    
    # Create a temporary file without the processed repository
    local temp_file="${PENDING_LIST}.tmp"
    local search_pattern="${repo_name}|${repo_url}"
    
    grep -v -F "$search_pattern" "$PENDING_LIST" > "$temp_file" || true
    mv "$temp_file" "$PENDING_LIST"
    
    log "INFO" "Removed $repo_name from pending list"
}

# Display current status
display_status() {
    local pending_count=$(wc -l < "$PENDING_LIST" 2>/dev/null || echo "0")
    local validated_count=$(($(wc -l < "$VALIDATED_LIST" 2>/dev/null || echo "0") - 3))  # Subtract header lines
    
    if [[ $validated_count -lt 0 ]]; then
        validated_count=0
    fi
    
    echo ""
    echo "=================================="
    echo "CURRENT STATUS"
    echo "=================================="
    echo "Pending repositories: $pending_count"
    echo "Validated repositories: $validated_count"
    echo "=================================="
    echo ""
}

# Process a single repository
process_repository() {
    local repo_name=$1
    local repo_url=$2
    local repo_path="$CLONE_DIR/$repo_name"
    
    log "INFO" "${BLUE}========================================${NC}"
    log "INFO" "${BLUE}Processing repository: $repo_name${NC}"
    log "INFO" "${BLUE}URL: $repo_url${NC}"
    log "INFO" "${BLUE}========================================${NC}"
    
    # Clone repository
    if ! clone_repository "$repo_url"; then
        remove_from_pending_list "$repo_name" "$repo_url"
        display_status
        return 1
    fi
    
    # Validate structure
    if ! validate_repository_structure "$repo_path"; then
        remove_repository "$repo_path"
        remove_from_pending_list "$repo_name" "$repo_url"
        display_status
        return 1
    fi
    
    # Compile repository
    if ! compile_repository "$repo_path"; then
        remove_repository "$repo_path"
        remove_from_pending_list "$repo_name" "$repo_url"
        display_status
        return 1
    fi
    
    # Run tests
    if ! run_tests "$repo_path"; then
        remove_repository "$repo_path"
        remove_from_pending_list "$repo_name" "$repo_url"
        display_status
        return 1
    fi
    
    # Repository passed all validations
    log "INFO" "${GREEN}✓ Repository $repo_name successfully validated and kept${NC}"
    
    # Remove from pending and add to validated
    remove_from_pending_list "$repo_name" "$repo_url"
    add_to_validated_list "$repo_name" "$repo_url"
    
    display_status
    return 0
}

# Generate summary report
generate_report() {
    log "INFO" "${BLUE}Generating summary report...${NC}"
    
    local validated_count=$(($(wc -l < "$VALIDATED_LIST" 2>/dev/null || echo "0") - 3))
    if [[ $validated_count -lt 0 ]]; then
        validated_count=0
    fi
    
    local successful_repos=$(find "$CLONE_DIR" -maxdepth 1 -type d | grep -v "^$CLONE_DIR$" | wc -l)
    
    echo ""
    echo "=================================="
    echo "REPOSITORY VALIDATION SUMMARY"
    echo "=================================="
    echo "Successfully validated: $validated_count"
    echo "Repositories in storage: $successful_repos"
    echo ""
    echo "Validated repositories list: $VALIDATED_LIST"
    echo "Cloned repositories directory: $CLONE_DIR"
    echo "Full log available at: $LOG_FILE"
    echo ""
    
    if [[ $validated_count -gt 0 ]]; then
        echo "Validated Repositories:"
        echo "----------------------"
        tail -n +4 "$VALIDATED_LIST"
    fi
    
    echo "=================================="
}

# Cleanup function
cleanup() {
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
    
    # Display initial status
    display_status
    
    # Process each repository
    local successful=0
    local failed=0
    
    while IFS='|' read -r repo_name repo_url; do
        if [[ -n "$repo_name" && -n "$repo_url" ]]; then
            if process_repository "$repo_name" "$repo_url"; then
                ((successful++))
            else
                ((failed++))
            fi
        fi
    done < <(cat "$PENDING_LIST")
    
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
    echo "  -m, --max NUM       Set maximum repositories to process (default: 50)"
    echo ""
    echo "Environment variables:"
    echo "  GITHUB_TOKEN        GitHub API token for authenticated requests"
    echo ""
    echo "Output files:"
    echo "  pending_repos.txt      List of repositories pending validation"
    echo "  validated_repos.txt    List of successfully validated repositories"
    echo "  repo_validation.log    Detailed execution log"
    echo ""
    echo "Examples:"
    echo "  $0                  # Run with default settings"
    echo "  $0 -t your_token    # Run with GitHub token"
    echo "  $0 -d /tmp/repos    # Use custom clone directory"
    echo "  $0 -m 20            # Process maximum 20 repositories"
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
        *)
            log "ERROR" "Unknown option: $1"
            usage
            exit 1
            ;;
    esac
done

# Run main function
main