# Turbostat Hardware Feature Visibility on AWS EC2 Instances

## Overview
On AWS EC2 instances, hardware feature visibility is limited by virtualization. The level of access to hardware metrics and features varies based on the instance type and virtualization layer.

## Instance Types and Hardware Access

### Bare Metal Instances
* Instances like `m7a.metal` and `c7a.metal` provide direct access to hardware, offering more detailed metrics and features
* Full visibility into hardware capabilities and performance counters

### Virtualized Instances
* Non-bare-metal instances have limited access to hardware features
* Many hardware features are abstracted or hidden by the AWS hypervisor
* Access to MSRs (Model-Specific Registers) may be restricted

## Available Performance Metrics on Virtualized/EC2 Instances

### Core Metrics
* **Avg_MHz**: Average processor frequency
* **Busy%**: CPU utilization percentage
* **Bzy_MHz**: Processor frequency during active periods
* **TSC_MHz**: Time Stamp Counter frequency
* **IPC**: Instructions Per Cycle
* **IRQ**: Interrupt count statistics

### Power Management States
* **POLL%**: Time spent in polling state
* **C1%**: Time in light sleep state
* **C2%**: Time in deeper sleep state (values over 99% indicate system idling)

## Notes: Limitations

```bash
CPUID(6): APERF, No-TURBO, No-DTS, No-PTM, No-HWP, No-HWPnotify, No-HWPwindow, No-HWPepp, No-HWPpkg, No-EPB
```
This shows many hardware power management features are not exposed to the EC2 VM by design.

Even though the AMD EPYC processor physically supports more C-states (C3-C6), the AWS hypervisor abstracts these away and presents a simplified model with just POLL, C1, and C2.

These limitations are intentional design choices in the AWS virtualization infrastructure.