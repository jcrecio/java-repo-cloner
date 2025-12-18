FROM maven:3.8-openjdk-8

# Install required tools
RUN apt-get update && \
    apt-get install -y \
    git \
    curl \
    jq \
    && rm -rf /var/lib/apt/lists/*

# Set working directory
WORKDIR /workspace

# Create necessary directories
RUN mkdir -p /workspace/cloned_repos

# Copy the validation script
COPY cloner.sh /workspace/cloner.sh
RUN chmod +x /workspace/cloner.sh

# Set environment variable to indicate running in Docker
ENV RUNNING_IN_DOCKER=true

# Default entrypoint
ENTRYPOINT ["/workspace/cloner.sh"]