# AWS Infrastructure Setup Guide: Amazon API Gateway

This document details the exact steps taken to provision the HTTP API front door for the Automated Log Anomaly Detector project. 

*Naming Convention Note:* All resources use the `Incident...` prefix or project name for consistency.

## Overview
*   **Service Used:** Amazon API Gateway (HTTP API)
*   **Purpose:** Provide a public HTTPS endpoint that receives log batches from collectors and routes them to the Ingestion Lambda function (`IncidentIngestFn`).
*   **Cost Strategy:** HTTP APIs are significantly cheaper than REST APIs and fall well within the 1 million free requests per month tier.

---

## Step-by-Step Instructions

### 1. Create the API
1. In the AWS Management Console, search for and select **API Gateway**.
2. Scroll down to the **HTTP API** section (do not choose REST API or WebSocket API) and click **Build**.
3. **API name:** `IncidentCorrelationAI-API`
4. Click **Next**.

### 2. Configure Integrations
*Note: The AWS UI requires you to add the Lambda integration before defining the route.*
1. Under the **Integrations** section, click **Add integration**.
2. Select **Lambda** as the integration type.
3. Under **Lambda function**, select `IncidentIngestFn`.
4. Click **Add** (or Create) to save the integration.
5. Click the orange **Next** button at the bottom right.

### 3. Define the Route
1. **Method:** Select `POST`.
2. **Resource path:** Type `/api/v1/events/batch`.
3. **Integration target:** Ensure `IncidentIngestFn` is selected.
4. Click **Next**.

### 4. Define Stages
1. Leave the stage name as **`$default`** (this is standard for HTTP APIs).
2. Click **Next**.

### 5. Review and Create
1. Review the settings.
2. Click the orange **Create** button.

### 6. Retrieve the Invoke URL
*Note: Because the `$default` stage has "Auto-deploy enabled", you do not need to manually click the Deploy button.*
1. On the left-hand navigation menu, under the **Deploy** section, click on **Stages**.
2. Click on the **`$default`** stage.
3. At the top of the page, copy the **Invoke URL** (e.g., `https://[random-id].execute-api.[region].amazonaws.com`). 
4. Save this URL; it is the endpoint your log collectors will send POST requests to.

---
## Expected Outcome
You now have a live API endpoint (e.g., `https://[random-id].execute-api.[region].amazonaws.com/api/v1/events/batch`) that is ready to receive HTTP POST requests from your log collectors and forward the JSON payloads to the `IncidentIngestFn` Lambda function.