"""
OCI Functions entry point for the weekly AMD policy regeneration.

This file exists because OCI Functions is the one target of the four that does
not simply run a container's command. Lambda takes a zip and a handler name;
Cloud Run Jobs and Container Apps Jobs run the image's entrypoint and exit.
Fn (which OCI Functions is built on) expects a long-running listener started by
the `fdk` CLI, calling a handler with the signature

    handler(ctx, data: io.BytesIO) -> response

So OCI gets this thin adapter and its own Dockerfile. The actual work is still
runner.run(), unchanged and shared with the other three clouds - the only thing
specific to OCI here is the calling convention.

Configuration comes from the Functions application config (set by Terraform),
which Fn surfaces as environment variables.
"""
import json
import os
import traceback

import runner


def handler(ctx, data=None):
    """Invoked by Resource Scheduler once a week, or by `oci fn function invoke`.

    The body is ignored. A scheduled trigger sends nothing useful, and this
    function deliberately takes no caller-supplied parameters - what it sweeps
    is a property of the deployment, not of whoever managed to invoke it.
    """
    try:
        store = runner.OCIStore(
            bucket=os.environ['ARTIFACT_BUCKET'],
            namespace=os.environ['OCI_NAMESPACE'],
            prefix=os.environ.get('ARTIFACT_PREFIX', 'amd-iam-policies'),
        )
        result = runner.run(
            backend='oci',
            secret_ref=os.environ['CCA_SECRET_ID'],
            store=store,
            notify_target=os.environ.get('NOTIFY_TOPIC_ID'),
            clouds=[c for c in os.environ.get('CLOUDS', '').split(',') if c],
            insecure=os.environ.get('INSECURE_TLS') == 'true',
        )
        return json.dumps(result)
    except Exception:
        # Print the traceback so it reaches the function's logs, then re-raise.
        # Returning an error object here would be recorded as a successful
        # invocation, which would make the failure invisible to exactly the
        # alarm you would set to catch it.
        traceback.print_exc()
        raise
