# Container image for the scheduled runs on Azure and GCP.
#
# Two clouds do not use this file:
#   AWS - Lambda takes the plain zip from package.sh, no build step at all.
#   OCI - Functions runs the Fn contract (an fdk listener calling a named
#         handler), not a container command, so it has its own image and
#         handler shim at automation/oci/Dockerfile + automation/oci/func.py.
#
# Azure Container Apps Jobs and GCP Cloud Run Jobs both run the entrypoint
# once and treat exit 0 as success, so those two share this image.
#
# Build from the REPO ROOT, not from automation/ - generate.py lives one level
# up and Docker cannot COPY from outside the build context:
#
#   docker build -f automation/Dockerfile --build-arg CLOUD=azure \
#     -t myacr.azurecr.io/amd-iam-policies:2026-10-21 .
#   docker push myacr.azurecr.io/amd-iam-policies:2026-10-21
#
# Tag with a date, not :latest. A scheduled job that silently picks up a new
# :latest is a policy generator you no longer control.

FROM python:3.13-slim

# generate.py is stdlib-only by design. The cloud SDKs below are needed only
# by runner.py, to read the token out of the platform's secret store and to
# write artifacts to its object store - one cloud's worth is installed per
# build to keep the image small and the dependency surface honest.
ARG CLOUD=azure

WORKDIR /app

RUN set -eux; \
    case "$CLOUD" in \
      azure) pip install --no-cache-dir \
               azure-identity==1.19.0 \
               azure-keyvault-secrets==4.9.0 \
               azure-storage-blob==12.24.0 ;; \
      gcp)   pip install --no-cache-dir \
               google-cloud-secret-manager==2.21.1 \
               google-cloud-storage==2.19.0 \
               google-cloud-pubsub==2.27.1 ;; \
      oci)   echo "OCI does not use this image - build automation/oci/Dockerfile instead" >&2; exit 1 ;; \
      *)     echo "unknown CLOUD=$CLOUD (want azure|gcp)" >&2; exit 1 ;; \
    esac

COPY generate.py            /app/generate.py
COPY automation/runner.py   /app/runner.py

# Run as a non-root user. The only writable path the job needs is /tmp, which
# is where runner.py puts its scratch directory.
RUN useradd --create-home --uid 10001 runner
USER runner

ENTRYPOINT ["python", "/app/runner.py"]
