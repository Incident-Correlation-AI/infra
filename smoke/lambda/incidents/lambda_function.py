"""SMOKE placeholder for admin incident routes. Returns contract-ish empty/simple shapes.
Authorization is NOT implemented in placeholders - the backend team's real code owns authz."""
import json
import os

import boto3

TABLE = os.environ.get("INCIDENT_TABLE", "")

CORS = {
    "Access-Control-Allow-Origin": "http://localhost:5173",
    "Access-Control-Allow-Headers": "Authorization,Content-Type,X-Request-Id",
}


def _resp(status: int, body: dict) -> dict:
    return {"statusCode": status, "body": json.dumps(body), "headers": CORS}


def handler(event, context):
    path = event.get("rawPath", "")
    table = boto3.resource("dynamodb").Table(TABLE)
    if path == "/api/v1/incidents":
        try:
            resp = table.query(
                IndexName="gsi1",
                KeyConditionExpression="gsi1pk = :s",
                ExpressionAttributeValues={":s": "STATUS#open"},
            )
            return _resp(200, {"items": resp.get("Items", []), "next_cursor": None})
        except Exception:
            return _resp(200, {"items": [], "next_cursor": None})
    return _resp(404, {"error": {"code": "not_found", "message": "smoke placeholder returns list only"}})
