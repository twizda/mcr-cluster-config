# Use a lightweight Python image
FROM python:3.11-slim

# Set working directory
WORKDIR /app

# Install required library
RUN pip install --no-cache-dir requests

# Copy the script
COPY mke_inventory.py .

# Run the script when the container starts
CMD ["python", "mke_inventory.py"]
