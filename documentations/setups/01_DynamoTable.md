# AWS Infrastructure Setup Guide: Amazon DynamoDB

This document details the exact steps taken to provision the primary database for the Automated Log Anomaly Detector project. 

## Overview
*   **Service Used:** Amazon DynamoDB
*   **Purpose:** Store incidents, deduplication records, and baseline state using a single-table design.
*   **Cost Strategy:** On-Demand capacity to stay within the AWS Free Tier.

---

## Step-by-Step Instructions

### 1. Access the Service
1. Log in to the AWS Management Console.
2. In the top search bar, type **DynamoDB** and select the service.

### 2. Initiate Table Creation
1. Click the orange **Create table** button.

### 3. Basic Configuration
1. **Table name:** Enter `IncidentTable` (or `lad-incidents`).
2. **Partition key:** Enter `pk` and select **String**.
3. **Sort key:** Enter `sk` and select **String**.

### 4. Table Class & Capacity
1. **Table class:** Select **DynamoDB Standard**. *(This is optimized for frequently accessed data).*
2. **Capacity mode:** Select **On-demand**. *(Crucial: This ensures you only pay for the reads/writes you actually use, preventing charges for idle time and keeping you within the Free Tier).*
3. **Capacity calculator:** Ignore this section (leave defaults).

### 5. Secondary Indexes (Global Secondary Index)
*Why:* We need this to quickly filter and query incidents by their status (e.g., "Show all open incidents") without scanning the whole table.
1. Scroll to **Secondary indexes** and click **Create global index**.
2. **Index name:** `gsi1`
3. **Partition key:** `gsi1pk` (Data type: **String**)
4. **Sort key:** `gsi1sk` (Data type: **String**)
5. **Attribute projections:** Select **All**. *(This ensures the dashboard can read all incident details directly from the index).*
6. **Warm throughput:** Leave blank/default.
7. Click **Create index** to save this configuration.

### 6. Security & Protection
1. **Vector indexes:** Skip (not used in this project).
2. **Encryption at rest:** Leave on **AWS-owned key** (Default, free, and secure).
3. **Deletion protection:** **Turn ON**. *(This prevents accidentally deleting the database during the hackathon).*
4. **Resource-based policy:** Leave blank.

### 7. Finalize
1. Scroll to the bottom of the page and click the orange **Create table** button.
2. Wait approximately 10–20 seconds for the table status to change from *Creating* to **Active**.

---
## Expected Outcome
You now have an active DynamoDB table named `IncidentTable` with a primary key (`pk`, `sk`) and one Global Secondary Index (`gsi1`), configured securely and ready to store incident data.