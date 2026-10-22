#!/usr/bin/env bash
# LAD infra provisioning via AWS CLI — corrected, idempotent version of the CLI recipe.
# Reuses console-created resources (documentations/setups/01-03), attaches scoped policies,
# fills wiring gaps, uploads SMOKE placeholders, verifies end-to-end and prints evidence.
#
# Prerequisites:
#   * authenticated aws CLI  -> user runs `aws configure` once (never paste keys in chat)
#   * python3 (function zips are built with stdlib zipfile)
set -euo pipefail

REGION="eu-north-1"
AWSX="aws --region $REGION"
say()  { printf '\n=== %s ===\n' "$*"; }
step() { printf '  - %s\n' "$*"; }
die()  { printf '  FATAL: %s\n' "$*" >&2; exit 1; }

say "Preflight"
IAM_ARN="$($AWSX sts get-caller-identity --query Arn --output text)" || die "not authenticated — run: aws configure"
ACCOUNT_ID="$($AWSX sts get-caller-identity --query Account --output text)"
step "identity: $IAM_ARN"
step "account=$ACCOUNT_ID region=$REGION"

say "1/8 SQS queues (reuse if present)"
DLQ_URL="$($AWSX sqs get-queue-url --queue-name IncidentDLQ --query QueueUrl --output text 2>/dev/null || true)"
if [ -z "$DLQ_URL" ]; then
  DLQ_URL="$($AWSX sqs create-queue --queue-name IncidentDLQ --query QueueUrl --output text)"
  step "created IncidentDLQ"
fi
MAIN_QUEUE_URL="$($AWSX sqs get-queue-url --queue-name IncidentMainQueue --query QueueUrl --output text 2>/dev/null || true)"
if [ -z "$MAIN_QUEUE_URL" ]; then
  DLQ_ARN="$($AWSX sqs get-queue-attributes --queue-url "$DLQ_URL" --attribute-names QueueArn --query Attributes.QueueArn --output text)"
  REDRIVE="{\"deadLetterTargetArn\":\"$DLQ_ARN\",\"maxReceiveCount\":\"5\"}"
  MAIN_QUEUE_URL="$($AWSX sqs create-queue --queue-name IncidentMainQueue \
    --attributes "{\"VisibilityTimeout\":\"120\",\"RedrivePolicy\":\"$REDRIVE\"}" --query QueueUrl --output text)"
  step "created IncidentMainQueue (vis 120, redrive 5 -> DLQ)"
fi
step "main=$MAIN_QUEUE_URL"
step "dlq =$DLQ_URL"

say "2/8 DynamoDB table (reuse) + TTL attribute"
if ! $AWSX dynamodb describe-table --table-name IncidentTable >/dev/null 2>&1; then
  $AWSX dynamodb create-table --table-name IncidentTable \
    --attribute-definitions AttributeName=pk,AttributeType=S AttributeName=sk,AttributeType=S AttributeName=gsi1pk,AttributeType=S AttributeName=gsi1sk,AttributeType=S \
    --key-schema AttributeName=pk,KeyType=HASH AttributeName=sk,KeyType=RANGE \
    --global-secondary-indexes '[{"IndexName":"gsi1","KeySchema":[{"AttributeName":"gsi1pk","KeyType":"HASH"},{"AttributeName":"gsi1sk","KeyType":"RANGE"}],"Projection":{"ProjectionType":"ALL"}}]' \
    --billing-mode PAY_PER_REQUEST >/dev/null
  $AWSX dynamodb wait table-exists --table-name IncidentTable
  step "created IncidentTable (pk/sk String, gsi1 ALL, on-demand)"
else
  step "reuse IncidentTable (deletion protection untouched)"
fi
$AWSX dynamodb update-time-to-live --table-name IncidentTable \
  --time-to-live-specification '{"Enabled":true,"AttributeName":"ttl"}' >/dev/null
step "TTL enabled on attribute ttl"

say "3/8 IAM — scoped policies, no wildcards"
MAIN_ARN="arn:aws:sqs:$REGION:$ACCOUNT_ID:IncidentMainQueue"
TBL_ARN="arn:aws:dynamodb:$REGION:$ACCOUNT_ID:table/IncidentTable"
GSI_ARN="$TBL_ARN/index/gsi1"

DOC_INGEST="{\"Version\":\"2012-10-17\",\"Statement\":[{\"Sid\":\"SendToMainQueue\",\"Effect\":\"Allow\",\"Action\":\"sqs:SendMessage\",\"Resource\":\"$MAIN_ARN\"}]}"
DOC_WORKER="{\"Version\":\"2012-10-17\",\"Statement\":[{\"Sid\":\"ConsumeQueue\",\"Effect\":\"Allow\",\"Action\":[\"sqs:ReceiveMessage\",\"sqs:DeleteMessage\",\"sqs:ChangeMessageVisibility\",\"sqs:GetQueueAttributes\"],\"Resource\":\"$MAIN_ARN\"},{\"Sid\":\"TableCRUD\",\"Effect\":\"Allow\",\"Action\":[\"dynamodb:PutItem\",\"dynamodb:GetItem\",\"dynamodb:UpdateItem\",\"dynamodb:DeleteItem\",\"dynamodb:Query\",\"dynamodb:ConditionCheckItem\"],\"Resource\":[\"$TBL_ARN\",\"$GSI_ARN\"]}]}"
DOC_API="{\"Version\":\"2012-10-17\",\"Statement\":[{\"Sid\":\"TableReadList\",\"Effect\":\"Allow\",\"Action\":[\"dynamodb:Query\",\"dynamodb:GetItem\"],\"Resource\":[\"$TBL_ARN\",\"$GSI_ARN\"]}]}"

ROLE_INGEST="$($AWSX iam list-roles --query "Roles[?starts_with(RoleName,'IncidentIngestFn-role-')].RoleName | [0]" --output text)"
ROLE_WORKER="$($AWSX iam list-roles --query "Roles[?starts_with(RoleName,'IncidentWorkerFn-role-')].RoleName | [0]" --output text)"
[ "$ROLE_INGEST" != "None" ] && [ -n "$ROLE_INGEST" ] || die "IngestFn role not found (console chapter 03 must have created the function)"
[ "$ROLE_WORKER" != "None" ] && [ -n "$ROLE_WORKER" ] || die "WorkerFn role not found (console chapter 03 must have created the function)"

TRUST='{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":{"Service":"lambda.amazonaws.com"},"Action":"sts:AssumeRole"}]}'
ROLE_API="IncidentApiFnRole"
if ! $AWSX iam get-role --role-name "$ROLE_API" >/dev/null 2>&1; then
  ROLE_API_ARN="$($AWSX iam create-role --role-name "$ROLE_API" --assume-role-policy-document "$TRUST" --query Role.Arn --output text)"
  $AWSX iam attach-role-policy --role-name "$ROLE_API" --policy-arn arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole
  step "created $ROLE_API (basic exec)"
else
  ROLE_API_ARN="$($AWSX iam get-role --role-name "$ROLE_API" --query Role.Arn --output text)"
  step "reuse role $ROLE_API"
fi

$AWSX iam put-role-policy --role-name "$ROLE_INGEST" --policy-name lad-sqs-send --policy-document "$DOC_INGEST" >/dev/null
$AWSX iam put-role-policy --role-name "$ROLE_WORKER" --policy-name lad-worker-sqs-ddb --policy-document "$DOC_WORKER" >/dev/null
$AWSX iam put-role-policy --role-name "$ROLE_API"    --policy-name lad-incident-read --policy-document "$DOC_API" >/dev/null
step "scoped inline policies on: $ROLE_INGEST, $ROLE_WORKER, $ROLE_API"

say "4/8 Package smoke placeholders into zips"
SMOKE_DIR="$(cd "$(dirname "$0")/../smoke/lambda" && pwd)"
for fn in ingest worker incidents; do
  (cd "$SMOKE_DIR/$fn" && python3 -m zipfile -c "$fn.zip" lambda_function.py)
  step "packaged $fn.zip"
done

say "5/8 Functions: placeholders + config"
ENVFILE="$(mktemp)"
python3 - "$ENVFILE" "$MAIN_QUEUE_URL" "$DLQ_URL" <<'PY'
import json, sys
path, main, dlq = sys.argv[1], sys.argv[2], sys.argv[3]
env = {"Variables": {
    "LAD_MODE": "aws", "LAD_ENV": "dev", "LAD_LOG_LEVEL": "INFO",
    "INCIDENT_TABLE": "IncidentTable",
    "MAIN_QUEUE_URL": main, "DLQ_URL": dlq,
}}
open(path, "w").write(json.dumps(env))
PY

upsert_fn() { # name role_arn zip timeout
  local name="$1" role="$2" zip="$3" timeout="$4"
  if $AWSX lambda get-function --function-name "$name" >/dev/null 2>&1; then
    $AWSX lambda update-function-configuration --function-name "$name" \
      --timeout "$timeout" --memory-size 512 --environment "file://$ENVFILE" >/dev/null
    $AWSX lambda update-function-code --function-name "$name" --zip-file "fileb://$zip" >/dev/null
    step "updated $name (code + ${timeout}s/512MB + env)"
  else
    $AWSX lambda create-function --function-name "$name" --runtime python3.12 \
      --role "$role" --handler lambda_function.lambda_handler \
      --zip-file "fileb://$zip" --timeout "$timeout" --memory-size 512 \
      --environment "file://$ENVFILE" --query FunctionArn --output text >/dev/null
    step "created $name ($role)"
  fi
}

ROLE_INGEST_ARN="$($AWSX iam get-role --role-name "$ROLE_INGEST" --query Role.Arn --output text)"
ROLE_WORKER_ARN="$($AWSX iam get-role --role-name "$ROLE_WORKER" --query Role.Arn --output text)"
upsert_fn IncidentIngestFn "$ROLE_INGEST_ARN" "$SMOKE_DIR/ingest/ingest.zip"       30
upsert_fn IncidentWorkerFn "$ROLE_WORKER_ARN" "$SMOKE_DIR/worker/worker.zip"       60
upsert_fn IncidentApiFn    "$ROLE_API_ARN"   "$SMOKE_DIR/incidents/incidents.zip" 30

say "6/8 Worker event source mapping"
MAPPING_EXISTS="$($AWSX lambda list-event-source-mappings --function-name IncidentWorkerFn \
  --query "EventSourceMappings[?EventSourceArn=='$MAIN_ARN'].UUID | [0]" --output text || true)"
if [ -z "$MAPPING_EXISTS" ] || [ "$MAPPING_EXISTS" = "None" ]; then
  $AWSX lambda create-event-source-mapping --function-name IncidentWorkerFn \
    --event-source-arn "$MAIN_ARN" --batch-size 10 \
    --maximum-batching-window-in-seconds 5 \
    --function-response-types ReportBatchItemFailures \
    --query UUID --output text >/dev/null
  step "created mapping (batch 10, window 5s, ReportBatchItemFailures)"
else
  step "mapping already exists ($MAPPING_EXISTS)"
fi

say "7/8 API Gateway (HTTP API) + integrations + routes + CORS + throttling"
API_ID="$($AWSX apigatewayv2 get-apis --query "Items[?Name=='IncidentCorrelationAI-API'].ApiId | [0]" --output text)"
if [ -z "$API_ID" ] || [ "$API_ID" = "None" ]; then
  CORS='{"AllowOrigins":["http://localhost:5173"],"AllowMethods":["GET","POST","OPTIONS"],"AllowHeaders":["Content-Type","Authorization","X-Request-Id"]}'
  API_ID="$($AWSX apigatewayv2 create-api --name IncidentCorrelationAI-API --protocol-type HTTP --cors-configuration "$CORS" --query ApiId --output text)"
  step "created HTTP API + CORS"
else
  step "reuse API $API_ID"
fi
$AWSX apigatewayv2 update-api --api-id "$API_ID" \
  --cors-configuration '{"AllowOrigins":["http://localhost:5173"],"AllowMethods":["GET","POST","OPTIONS"],"AllowHeaders":["Content-Type","Authorization","X-Request-Id"]}' >/dev/null
step "CORS pinned to http://localhost:5173 (never '*')"

ing_arn="$($AWSX lambda get-function --function-name IncidentIngestFn --query Configuration.FunctionArn --output text)"
api_arn="$($AWSX lambda get-function --function-name IncidentApiFn   --query Configuration.FunctionArn --output text)"

integration_for() { # fn_arn -> id (create if absent)
  local target="$1"
  local found="$($AWSX apigatewayv2 get-integrations --api-id "$API_ID" --query "Items[?IntegrationUri=='$target'].IntegrationId | [0]" --output text)"
  if [ -z "$found" ] || [ "$found" = "None" ]; then
    $AWSX apigatewayv2 create-integration --api-id "$API_ID" --integration-type AWS_PROXY \
      --integration-uri "$target" --payload-format-version 2.0 --query IntegrationId --output text
  else
    printf '%s' "$found"
  fi
}
I_INGEST="$(integration_for "$ing_arn")"
I_API="$(integration_for "$api_arn")"
step "integrations ingest=$I_INGEST api=$I_API"

add_route() { # method path integration
  $AWSX apigatewayv2 create-route --api-id "$API_ID" --route-key "$1 $2" --target "integrations/$3" >/dev/null 2>&1 \
    && step "route  $1 $2" || step "route  $1 $2  (exists)"
}
add_route POST  "/api/v1/events/batch"                          "$I_INGEST"
add_route GET   "/api/v1/health"                                "$I_INGEST"
add_route GET   "/api/v1/incidents"                             "$I_API"
add_route GET   "/api/v1/incidents/{incident_id}"               "$I_API"
add_route POST  "/api/v1/incidents/{incident_id}/acknowledge"   "$I_API"
add_route POST  "/api/v1/incidents/{incident_id}/resolve"       "$I_API"

$AWSX lambda add-permission --function-name IncidentIngestFn --statement-id apigw-invoke \
  --action lambda:InvokeFunction --principal apigateway.amazonaws.com \
  --source-arn "arn:aws:execute-api:$REGION:$ACCOUNT_ID:$API_ID/*/*" >/dev/null 2>&1 && step "grant InvokeFunction -> IncidentIngestFn" || step "grant IncidentIngestFn (already present)"
$AWSX lambda add-permission --function-name IncidentApiFn --statement-id apigw-invoke \
  --action lambda:InvokeFunction --principal apigateway.amazonaws.com \
  --source-arn "arn:aws:execute-api:$REGION:$ACCOUNT_ID:$API_ID/*/*" >/dev/null 2>&1 && step "grant InvokeFunction -> IncidentApiFn" || step "grant IncidentApiFn (already present)"

$AWSX apigatewayv2 update-stage --api-id "$API_ID" --stage-name '$default' --auto-deploy \
  --throttling-rate-limit 25 --throttling-burst-limit 50 >/dev/null 2>&1 \
  || $AWSX apigatewayv2 create-stage --api-id "$API_ID" --stage-name '$default' --auto-deploy >/dev/null
step "default stage: auto-deploy, throttle 25 rps / burst 50"

say "8/8 End-to-end verification (real output below)"
INVOKE_URL="$($AWSX apigatewayv2 get-api --api-id "$API_ID" --query ApiEndpoint --output text)"
step "invoke URL: $INVOKE_URL"
sleep 6
CODE_HEALTH="$(curl -s -o /dev/null -w '%{http_code}' "$INVOKE_URL/api/v1/health")"
step "GET /api/v1/health -> HTTP $CODE_HEALTH (200 expected)"
python3 - "$INVOKE_URL" <<'PY'
import json, sys, time, uuid, urllib.request
url = sys.argv[1]
batch = [{"schema_version": "1.0", "event_id": str(uuid.uuid4()),
          "event_ts": "2026-10-21T10:15:42Z", "observed_ts": "2026-10-21T10:15:42.400Z",
          "host": "host-alpha", "source": "app-nginx", "category": "http",
          "type": "wiresmoke", "severity": "error", "message": "wiring smoke"} for _ in range(2)]
req = urllib.request.Request(f"{url}/api/v1/events/batch",
                             data=json.dumps({"events": batch}).encode(),
                             headers={"Content-Type": "application/json"}, method="POST")
with urllib.request.urlopen(req) as r:
    print(f"  - POST /events/batch -> HTTP {r.status} {r.read().decode()}")
PY
sleep 15
QOUT="$($AWSX dynamodb query --table-name IncidentTable --key-condition-expression 'pk = :s' \
  --expression-attribute-values '{":s":{"S":"SMOKE"}}' \
  --query 'Items[].sk.S' --output text)"
if [ -n "$QOUT" ]; then
  step "DynamoDB SMOKE items written by worker (evidence): $QOUT"
  for sk in $QOUT; do
    $AWSX dynamodb delete-item --table-name IncidentTable --key "{\"pk\":{\"S\":\"SMOKE\"},\"sk\":{\"S\":\"$sk\"}}" >/dev/null
  done
  step "smoke items deleted (clean)"
else
  step "no SMOKE items yet — retry needed; check worker logs (/aws/lambda/IncidentWorkerFn)"
fi
step "DLQ depth: $($AWSX sqs get-queue-attributes --queue-url "$DLQ_URL" --attribute-names ApproximateNumberOfMessages --query Attributes.ApproximateNumberOfMessages --output text) (expect 0)"

TMP_FILES=("$ENVFILE" "$SMOKE_DIR"/ingest/ingest.zip "$SMOKE_DIR"/worker/worker.zip "$SMOKE_DIR"/incidents/incidents.zip)
rm -f "${TMP_FILES[@]}" 2>/dev/null || true

say "Summary"
step "Invoke URL for collectors/dashboard: $INVOKE_URL"
step "Record verified statuses in documentations/setups/README.md"
