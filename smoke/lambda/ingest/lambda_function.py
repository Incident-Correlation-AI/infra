"""SMOKE placeholder - proves gateway-to-SQS wiring. Replaced by backend team's real ingest code."""
import json
import os
import uuid

import boto3

QUEUE_URL = os.environ.get("MAIN_QUEUE_URL", "")


def _resp(status: int, body: dict) -> dict:
    return {"statusCode": status, "body": json.dumps(body)}


def handler(event, context):
    method = event.get("requestContext", {}).get("http", {}).get("method", "")
    path = event.get("rawPath") or event.get("requestContext", {}).get("http", {}).get("path", "")

    if method == "GET" and "health" in path:
        return _resp(200, {"status": "ok", "mode": "aws", "version": "smoke-0.1.0"})

    if method == "POST" and "events/batch" in path:
        try:
            body = json.loads(event.get("body") or "{}")
        except json.JSONDecodeError:
            return _resp(400, {"error": {"code": "validation_failed", "message": "invalid JSON"}})
        events = body.get("events", [])
        if not isinstance(events, list) or not events:
            return _resp(400, {"error": {"code": "validation_failed", "message": "events[] required"}})
        accepted = [e for e in events if isinstance(e, dict) and e.get("event_id")]
        if QUEUE_URL and accepted:
            sqs = boto3.client("sqs")
            sqs.send_message(QueueUrl=QUEUE_URL, MessageBody=json.dumps({"events": accepted}))
        return _resp(
            202,
            {
                "receipt_id": f"smoke_{uuid.uuid4().hex[:12]}",
                "accepted": len(accepted),
                "rejected": len(events) - len(accepted),
                "results": [],
                "note": "smoke placeholder: accepted events queued for asynchronous processing; detection has not run",
            },
        )
    return _resp(404, {"error": {"code": "not_found", "message": "no such route"}})
