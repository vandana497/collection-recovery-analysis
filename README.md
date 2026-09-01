# Collections Recovery Performance Analysis

## Overview

This project investigates whether the reported **11% month-on-month improvement in collections recovery** is supported by the underlying data.

Rather than accepting the reported KPI at face value, the analysis rebuilds the recovery metrics from the raw data, identifies major data-quality issues, tests alternative explanations for the observed trend, and evaluates whether a change in targeting strategy appears to have improved collections performance.

The project concludes with a business recommendation on whether a proposed **₹10 Cr investment in AI-powered voice automation** is justified.

---

## Business Questions

The analysis focuses on five questions:

1. Is the reported **11% MoM recovery improvement** actually supported by the data?
2. How much do duplicate and reversed payments affect reported recovery?
3. Are borrower, agent and account identifiers reliable enough for analysis?
4. Did vendor mix, portfolio mix or targeting strategy explain the recovery trend?
5. Should the business invest the full **₹10 Cr**, or start with a smaller controlled pilot?

---

## Key Findings

### 1. The reported 11% MoM improvement is not supported

After cleaning the payment data and rebuilding the recovery metric, no consistent 11% month-on-month improvement is observed.

The raw recovery numbers are materially affected by data-quality issues.

### 2. Raw recovery is overstated

Duplicate payment retries and reversed transactions inflate the naive recovery calculation by approximately **6–29% depending on the month**.

This means part of the apparent improvement in the raw KPI is caused by changing data quality rather than genuine collection performance.

### 3. Borrower IDs are unreliable

Approximately **98% of borrower IDs** across the event tables do not match the borrower associated with the same account in the source-of-truth account table.

The analysis therefore uses:

```text
account_id
```

as the reliable join key and derives borrower relationships from the account dimension.

### 4. Vendor and portfolio mix do not explain the trend

Monthly vendor volumes remain broadly stable.

The portfolio's risk-segment composition is also relatively stable.

There is therefore no strong evidence that either vendor mix or portfolio mix explains the reported recovery improvement.

### 5. Targeting strategy does not show a measurable effect

All four strategy versions were operating concurrently rather than in a clean before/after experiment.

Recovery per worked account is approximately:

**₹36,474–₹37,147**

across strategy versions, representing less than a 2% spread.

The available data therefore does not provide convincing evidence that targeting strategy materially changed recovery.

### 6. Voice is the most interesting channel for intervention

Field visits have the highest contact rate at approximately **66%**, but they are expensive.

Voice represents the largest collection channel by volume, with approximately **120K touches**, but has a contact rate of only around **20%**.

This makes voice the most promising channel to test for efficiency improvements.

---

## Business Recommendation

The analysis does **not** support immediately committing the full **₹10 Cr** investment.

Instead, the recommendation is to start with a:

### ₹1.5–2 Cr controlled pilot

The pilot should test AI-powered voice automation using a randomized control group.

Key metrics should include:

* Contact rate
* RPC rate
* PTP creation rate
* PTP kept rate
* Recovery per worked account
* Cost per successful recovery
* Human-agent escalation rate
* Customer-level outcomes

The solution should only be scaled if the experiment demonstrates a meaningful and repeatable improvement in incremental recovery.

---

## Project Structure

```text
collections-recovery-analysis/
│── golden_dataset/
|
├── notebooks/
│   └── analysis.ipynb
|    └── notebook.py
│
├── sql/
│   ├── 01_staging.sql
│   └── 02_golden.sql
│
|── architecture/
|   └── architecture.png
|
|── dashboard/
|    └── dashboard.html
|
├── dq_report/
│   └── data quality report.pdf
│
├── memo/
│   └── memo.pdf
│
│
├── README.md
├── requirements.txt
└── .gitignore
```

---

## Methodology

The analysis follows a layered approach:

```text
Raw Data
   ↓
Staging Layer
   ↓
Data Quality Checks
   ↓
Golden Dataset
   ↓
Independent Metrics
   ↓
Forensic Analysis
   ↓
Strategy Comparison
   ↓
Investment Recommendation
```

The Golden layer addresses:

* Duplicate records
* Payment retry chains
* Reversed transactions
* Corrupted borrower identifiers
* Duplicate agent/borrower dimensions
* Timezone normalization
* Reliable account-level joins

---

## Important Data Limitations

The analysis has several limitations that should be considered before using the findings operationally.

### Targeting strategy

There is no clean before/after strategy switch in the available data. Therefore, the analysis uses a matched cross-sectional comparison rather than a traditional difference-in-differences design.

### ROI assumptions

The raw dataset does not contain sufficient cost information to calculate ROI directly.

The investment scenarios therefore depend on explicit assumptions documented in the executive memo.

### PTP measurement

A 14-day PTP-kept window is used because a 3-day window produces an implausibly low result. Even with the wider window, the observed kept rate remains low.

These limitations reduce confidence in the exact ROI estimate but do not change the recommendation to validate the intervention through a controlled pilot.

---

## Tools Used

* **Python**
* **Pandas**
* **DuckDB**
* **SQL**
* **Jupyter Notebook**
* **Data Quality / Data Forensics**
* **Statistical Analysis**
* **Business Case & ROI Analysis**

---

## How to Run the Project

### 1. Clone the repository

```bash
git clone <your-github-repository-url>
cd collections-recovery-analysis
```

### 2. Create a virtual environment

```bash
python -m venv .venv
```

Activate it on Windows:

```bash
.venv\Scripts\activate
```

### 3. Install dependencies

```bash
pip install -r requirements.txt
```

### 4. Add the raw data

Raw data is intentionally excluded from the repository.

Place the required source files in the appropriate local data directory.

### 5. Run the notebook

```bash
jupyter notebook
```

Open:

```text
notebooks/analysis.ipynb
```

---

## Disclaimer

The dataset used for this project is not included in the public repository because the underlying collection data may contain sensitive or proprietary information.

The analysis is intended for demonstrating data-analysis methodology, data-quality investigation, statistical reasoning and business decision-making.
