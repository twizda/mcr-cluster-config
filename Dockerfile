# Use a lightweight Python image, pinned by digest for reproducible builds
FROM python:3.11-slim@sha256:e88e9763f943ec1834f992a4b51e0f24500486803e8bc534e5767af9ea65f6ce

# Install required libraries (versions and hashes pinned in requirements.txt), then remove
# the packaging toolchain (pip, setuptools, wheel), which is not needed at runtime and
# carries its own CVEs
COPY requirements.txt /opt/mke-inventory/requirements.txt
RUN pip install --no-cache-dir --require-hashes -r /opt/mke-inventory/requirements.txt \
    && pip uninstall -y setuptools wheel \
    && python -m pip uninstall -y pip

# Copy the script outside the output directory so a volume mount cannot replace it
COPY mke_inventory.py /opt/mke-inventory/mke_inventory.py

# Run as an unprivileged user; output is written to /out (mount a host directory there)
RUN useradd --system --uid 10001 --no-create-home --shell /usr/sbin/nologin mke \
    && mkdir /out && chown mke /out
USER 10001
WORKDIR /out
ENV OUTPUT_DIR=/out

# Run the script when the container starts
CMD ["python", "/opt/mke-inventory/mke_inventory.py"]
