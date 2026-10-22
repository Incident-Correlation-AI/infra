# AWS Infrastructure Setup Guide: Amazon SQS

This document details the exact steps taken to provision the message queues for the Automated Log Anomaly Detector project. 

*Naming Convention Note:* All resources use the `Incident...` prefix for consistency across the stack (e.g., `IncidentTable`, `IncidentMainQueue`).

## Overview
*   **Service Used:** Amazon Simple Queue Service (SQS)
*   **Purpose:** Buffer incoming log events between the Ingestion API and the Detection Worker, and catch failed messages so they don't get stuck in an infinite loop.
*   **Cost Strategy:** Standard queues, paying per request (well within the 1 million free requests/month tier).

---

## Step-by-Step Instructions

### Part 1: Create the Dead-Letter Queue (DLQ) First
*Note: The current AWS Console UI requires the DLQ to exist before you can link it to the main queue.*

1. In the AWS Management Console, search for and select **SQS**.
2. Click the orange **Create queue** button.
3. **Type:** Select **Standard**.
4. **Name:** `IncidentDLQ`
5. Leave all other settings as default (Encryption can be left disabled or set to SSE-SQS).
6. Click **Create queue**.
7. Once created, open `IncidentDLQ` and copy its **ARN** (Amazon Resource Name). It will look something like `arn:aws:sqs:eu-north-1:123456789012:IncidentDLQ`.

### Part 2: Create the Main Queue
1. Go back to the SQS dashboard and click **Create queue** again.
2. **Type:** Select **Standard**.
3. **Name:** `IncidentMainQueue`
4. **Configuration:**
   * **Visibility timeout:** Set to **`120` seconds**. *(This hides a message for 2 minutes while the Lambda worker processes it, preventing duplicate processing).*
   * Leave message retention and delivery delay as default.
5. **Encryption (Optional):** Select **Enabled** with **Amazon SQS key (SSE-SQS)** for security.
6. **Dead-letter queue:**
   * Select **Enabled**.
   * In the **Queue ARN** field, paste the ARN you copied for `IncidentDLQ`.
   * Set **Maximum receives** to **`5`**. *(If a worker fails to process a message 5 times, SQS automatically moves it to the DLQ).*
7. Click the orange **Create queue** button.

---
## Expected Outcome
You now have a standard buffering queue (`IncidentMainQueue`) and a safety net queue (`IncidentDLQ`) linked together via a redrive policy.