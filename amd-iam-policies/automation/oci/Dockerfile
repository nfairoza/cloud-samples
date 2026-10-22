# OCI Functions image. The other three clouds share ../Dockerfile; OCI cannot.
#
# Fn - which OCI Functions is built on - does not run a container's command and
# wait for it to exit. It expects the image to start the FDK listener, which
# then calls a named handler per invocation:
#
#   ENTRYPOINT ["/python/bin/fdk", "/function/func.py", "handler"]
#
# The shared image ends `ENTRYPOINT ["python", "/app/runner.py"]`, which starts,
# does the work and exits - correct for Container Apps Jobs and Cloud Run Jobs,
# and a function that never becomes ready on OCI. Hence this second file and
# the func.py shim beside it. Everything below /function is the same code the
# other clouds run; only the calling convention differs.
#
# Build from the REPO ROOT - generate.py lives two levels up:
#
#   docker build -f automation/oci/Dockerfile \
#     -t iad.ocir.io/<namespace>/amd/policies:2026-10-21 .
#   docker push iad.ocir.io/<namespace>/amd/policies:2026-10-21
#
# Tag with a date, not :latest. A scheduled job that silently picks up a new
# :latest is a policy generator you no longer control.

FROM fnproject/python:3.11-dev AS build-stage

WORKDIR /function

# fdk is the Fn contract itself; oci is what runner.py uses to reach Vault,
# Object Storage and ONS as a resource principal. generate.py needs neither -
# it is stdlib-only by design.
RUN pip install --no-cache-dir --target /python/ \
      fdk==0.1.78 \
      oci==2.149.0

FROM fnproject/python:3.11

WORKDIR /function

COPY --from=build-stage /python /python

COPY generate.py                /function/generate.py
COPY automation/runner.py       /function/runner.py
COPY automation/oci/func.py     /function/func.py

# /function first so `import runner` and `import generate` resolve; /python is
# where the dependencies above were installed.
ENV PYTHONPATH=/function:/python

ENTRYPOINT ["/python/bin/fdk", "/function/func.py", "handler"]
