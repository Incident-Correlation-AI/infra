# AWS Infrastructure Setup Guide: AWS Lambda

This document details the exact steps taken to provision the compute functions for the Automated Log Anomaly Detector project. 

*Naming Convention Note:* All resources use the `Incident...` prefix for consistency across the stack (e.g., `IncidentTable`, `IncidentMainQueue`, `IncidentIngestFn`).

## Overview
*   **Service Used:** AWS Lambda
*   **Purpose:** Run backend Python code without managing servers. We need two functions:
    1.  `IncidentIngestFn`: Receives API requests, validates log events, and pushes them to the SQS queue.
    2.  `IncidentWorkerFn`: Polls the SQS queue, runs anomaly detection logic, and saves incidents to DynamoDB.
*   **Cost Strategy:** Serverless compute (pay per request). The project's expected load is well within the "Always Free" tier of 1 million requests per month.

---

## Step-by-Step Instructions

### Part 1: Create the Ingestion Function
*Note: The AWS Lambda console UI was recently updated. Standard Lambda functions are now located under the "Event Functions" menu.*

1. In the AWS Management Console, search for and select **Lambda**.
2. On the left-hand navigation menu, click **Event Functions**.
3. Click the **Create function** (or **Create an Event Function**) button.
4. Under "Choose one of the following options", ensure **Author from scratch** is selected.
5. **Basic information:**
   * **Function name:** `IncidentIngestFn`
   * **Runtime:** Change the dropdown from Node.js to **Python 3.12** (or the highest available Python 3.x version).
6. **Custom settings:** Leave all settings collapsed and at their defaults. 
   * *Important:* Do not check "ARM64", "VPC", or "Function URL". AWS will automatically create a basic execution role for the function.
7. Click the orange **Create Event Function** (or **Create function**) button at the bottom.

### Part 2: Create the Worker Function
1. Once the first function is created, use the left-hand navigation menu to go back to **Event Functions**.
2. Click **Create function** again and repeat the exact same steps above.
3. **Function name:** `IncidentWorkerFn`
4. **Runtime:** **Python 3.12**
5. Click **Create Event Function**.

---
## Expected Outcome
You now have two active Lambda functions (`IncidentIngestFn` and `IncidentWorkerFn`) running Python 3.x. They are currently empty and do not have permission to talk to SQS or DynamoDB yet, but they are provisioned and ready for code.

---
**Next Steps (Not yet completed):**
*   Configure IAM permissions so `IncidentIngestFn` can write to `IncidentMainQueue`.
*   Configure IAM permissions so `IncidentWorkerFn` can read from `IncidentMainQueue` and write to `IncidentTable`.
*   Add Python code to both functions.
*   Set up API Gateway to trigger `IncidentIngestFn`.