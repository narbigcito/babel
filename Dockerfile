FROM python:3.13-slim

WORKDIR /app

# Install dependencies
COPY pyproject.toml .
RUN pip install --no-cache-dir -e "."

# Copy source code
COPY babel/ ./babel/

# Create config directory
RUN mkdir -p /root/.babel

# Expose port
EXPOSE 8787

# Run Babel
CMD ["python", "-m", "babel.cli", "start"]
