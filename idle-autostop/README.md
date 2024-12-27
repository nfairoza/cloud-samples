# AutoStop Lambda Function for EC2 Instances

This repository contains resources for deploying and managing an AWS Lambda function designed to optimize EC2 instance usage. The function scans for idle instances, sends notifications, and takes actions to prevent unnecessary costs.

## Features

### 1. **Instance Scanning**
- Scans all EC2 instances in the account, identifying those with **1-2% usage over 2-3 hours**.
- Checks instances for the `AutoStop: true` tag and ensures compliance.
- Also scans for instances without any tags (excluding the `Name` tag).

### 2. **Notification System**
- Sends email notifications with instance details (region, name, SKU, etc.) to the configured distribution list (`dl.aws_sol_architect`).
- For instances without the `AutoStop` tag, sends a warning email and adds the tag automatically.
- For instances without any tags (ignoring `Name`), sends an email to the team with the instance details.

### 3. **Automated Stop Mechanism**
- Stops instances with the `AutoStop: true` tag after identifying sustained idle usage.

### 4. **Weekly or Bi-Weekly Execution**
- Runs on a configurable cron schedule (e.g., every Friday at mid-day) using Amazon EventBridge.

### 5. **Tagging Considerations**
- Ignores the `Name` tag during scans but ensures other operational tags like `AutoStop` or `Email` are considered.



## How It Works

1. **Idle Instance Detection**
   - Identifies EC2 instances running below the specified CPU utilization threshold for a given period.

2. **Notification and Tagging**
   - Sends a notification for instances without the `AutoStop` tag and automatically adds the tag for future compliance.
   - Sends team-wide emails for instances without any tags (excluding `Name`).

3. **Instance Stopping**
   - Stops instances with the `AutoStop: true` tag.
