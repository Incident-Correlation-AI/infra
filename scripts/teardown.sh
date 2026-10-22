#!/usr/bin/env bash
# Documented cleanup. Deletes the stack; must be run deliberately per env.
# Note: S3 buckets (if any) must be emptied first; DynamoDB data is lost.
# Usage: ./teardown.sh dev    or   ./teardown.sh demo
set -euo pipefail

ENV="${1:?usage: teardown.sh <dev|demo>}"
case "$ENV" in
  dev|demo) ;;
  *) echo "Env must be dev or demo"; exit 1 ;;
esac
STACK="lad-${ENV}"

echo "==> Inspecting DLQ depth before delete (expected: nothing critical pending)"
aws cloudformation list-stack-resources --stack-name "$STACK" \
  --query "StackResourceSummaries[].{Logical:LogicalResourceId,Physical:PhysicalResourceId}" --output table || true

echo "==> Deleting stack ${STACK} (this removes queue, table, lambdas; DATA IS LOST)"
sam delete --stack-name "$STACK" --no-prompts
