# AutoStop Lambda Function for EC2 Instances

This repository contains resources for deploying and managing an AWS Lambda function designed to optimize EC2 instance usage. The function scans for idle instances, sends notifications, and takes actions to prevent unnecessary costs.


### 1. **Instance Scanning**
- Scans all EC2 instances in the account, identifying those with **1-2% usage over 2-3 hours**.
- Checks instances for the `AutoStop: true` tag and ensures compliance.
- Also scans for instances without any tags (excluding the `Name` tag).

### 2. **Notification**
- Sends email notifications with instance details (region, name, SKU, etc.) to the configured email or dl.
- For instances without the `AutoStop` tag, sends a warning email to the dl and adds the tag automatically.
- For instances without any other tags (ignoring `Name`), sends an email to the dl with the instance details.

### 3. **Automated Stop Mechanism**
- Stops instances with the `AutoStop: true` tag after identifying sustained idle usage.

### 4. **Weekly Execution**
- Runs on a configurable cron schedule using Amazon EventBridge which triggers the lambda function.
