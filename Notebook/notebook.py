import nbformat as nbf
nb = nbf.v4.new_notebook()
cells = []
def md(s): cells.append(nbf.v4.new_markdown_cell(s))
def code(s): cells.append(nbf.v4.new_code_cell(s))

md("""# Collections Recovery Performance — Analysis Notebook
Investigating whether "recovery improved 11% month-on-month" is real.

**Structure:** Part 1 Golden Dataset -> Part 2 Forensics -> Part 3 Statistical investigation ->
Part 4 Counterfactual & ROI. Every claim below is tagged **Fact**, **Strong evidence**,
**Correlation**, or **Hypothesis**.""")

code("""import duckdb, pandas as pd
pd.set_option('display.width', 160)
con = duckdb.connect('../raw.duckdb')
print(con.execute("SHOW TABLES").fetchdf())""")

md("## Part 1 — Golden Dataset\nStaging and golden-layer SQL are in `../sql/01_staging.sql` and `../sql/02_golden.sql`. "
   "We run them here so the notebook is reproducible end-to-end from raw CSVs.")

code("""con.execute(open('../sql/01_staging.sql').read())
con.execute(open('../sql/02_golden.sql').read())
print("Staging + golden layers built.")""")

md("""### Raw -> Rejected/Corrected -> Golden (quantified)
| Table | Raw | Corrected | Golden | Why |
|---|---|---|---|---|
| accounts | 30,000 | 0 | 30,000 | Already clean 1:1 dimension |
| borrowers | 30,600 | 19,585 | 11,015 | Only 11,015 real borrowers; rest are randomized-attribute duplicates |
| agents | 30,000 | 29,000 | 1,000 | Only 1,000 real agents; rest are randomized-attribute duplicates |
| calls | 91,350 | 1,350 | 90,000 | Exact duplicate call_id rows |
| payments | 25,500 | 4,310 | 21,190 | 500 exact dupes + retry-chain collapse |

Full reasoning for each decision is in `../dq_report/data_quality_report.md`.""")

md("## Part 2 — Forensics (A-G)\n### A. Duplicate payments — the single biggest correction")

code("""df = con.execute('''
WITH naive AS (
    SELECT DATE_TRUNC('month', event_at) mo, SUM(amount) naive_sum
    FROM payments WHERE payment_status='SUCCESS' GROUP BY 1
),
golden AS (
    SELECT DATE_TRUNC('month', event_at) mo, SUM(amount) golden_sum
    FROM stg_payments WHERE is_recognized_recovery GROUP BY 1
)
SELECT n.mo AS month, naive_sum/1e7 AS naive_recovery_cr, golden_sum/1e7 AS golden_recovery_cr,
       ROUND(100.0*(naive_sum-golden_sum)/naive_sum,1) AS pct_inflation
FROM naive n JOIN golden g ON n.mo=g.mo ORDER BY 1
''').fetchdf()
df""")

md("""**Fact:** naive (raw \"SUCCESS\" sum) recovery is inflated 6-29% by duplicate payment retries and
reversed transactions that were never actually collected. The inflation **shrinks steadily across
the year** — meaning part of the apparent MoM \"improvement\" in raw numbers is shrinking noise,
not more borrowers paying.""")

code("""df['naive_mom_pct'] = df['naive_recovery_cr'].pct_change()*100
df['golden_mom_pct'] = df['golden_recovery_cr'].pct_change()*100
df[['month','naive_recovery_cr','naive_mom_pct','golden_recovery_cr','golden_mom_pct']]""")

md("**Fact:** no single month matches the reported \"11%\" MoM figure in either the naive or golden series. "
   "August is a partial month (see cell below) and must be excluded from any trend claim.")

code("""con.execute('''SELECT DATE_TRUNC('month', event_at) mo, COUNT(*) n
FROM payments GROUP BY 1 ORDER BY 1''').fetchdf()""")

md("### B-C. Attribution & timezone\nMixed timezones (UTC / Asia/Kolkata / Asia/Dubai) on every event table — "
   "normalized to IST in staging using each row's own `timezone` column before any hour/day analysis.")

code("""con.execute("SELECT timezone, COUNT(*) FROM calls GROUP BY 1").fetchdf()""")

md("### D. Vendor mapping changes — ruled out")

code("""con.execute('''
SELECT DATE_TRUNC('month', event_at_ist) mo, vendor_id, COUNT(*) n
FROM stg_calls GROUP BY 1,2 ORDER BY 1,2
''').fetchdf().pivot(index='mo', columns='vendor_id', values='n')""")

md("**Strong evidence (ruled out):** call volume per vendor is stable/near-uniform every month. No routing or vendor-mix shift.")

md("### E. Agent & borrower identity corruption — a Fact that limits every downstream cut")

code("""print("Agents: raw rows vs distinct agent_id vs distinct employee_code")
print(con.execute("SELECT COUNT(*), COUNT(DISTINCT agent_id), COUNT(DISTINCT employee_code) FROM agents").fetchdf())
print()
print("One agent_id's raw rows (attributes are randomized, not a real history):")
con.execute("SELECT agent_id, employee_code, agent_name, team, vendor_id, status FROM agents WHERE agent_id='AGT0000875' LIMIT 6").fetchdf()""")

code("""print("borrower_id mismatch rate between event tables and accounts.csv (source of truth):")
for t in ['calls','payments','promises_to_pay','field_visits','complaints']:
    r = con.execute(f'''
        SELECT COUNT(*) total, SUM((e.borrower_id != a.borrower_id)::INT) mismatches
        FROM {t} e JOIN accounts a ON e.account_id = a.account_id
    ''').fetchdf()
    total, mism = r.iloc[0]
    print(f"  {t:20s} {mism/total*100:5.1f}% mismatch")""")

md("**Fact:** borrower_id is essentially random in every event table (~98% mismatch). account_id is the only "
   "trustworthy join key — every event table's borrower_id was dropped and re-derived at the golden layer.")

md("### F. Portfolio mix — ruled out")

code("""con.execute('''
SELECT DATE_TRUNC('month', opened_at) mo, risk_segment, COUNT(*) n
FROM stg_accounts GROUP BY 1,2 ORDER BY 1,2
''').fetchdf().pivot(index='mo', columns='risk_segment', values='n')""")

md("### G. Denominator manipulation — ruled out")

code("""con.execute('''
SELECT DATE_TRUNC('month', target_date) mo, status,
    ROUND(100.0*COUNT(*)/SUM(COUNT(*)) OVER (PARTITION BY DATE_TRUNC('month', target_date)),1) pct
FROM stg_daily_targeting GROUP BY 1,2 ORDER BY 1,2
''').fetchdf().pivot(index='mo', columns='status', values='pct')""")

md("**Strong evidence (ruled out):** targeting-queue status shares are flat ~25% each, every month.")

md("## Part 3 — Independent metric definitions & the real trend\n"
   "Definitions and rationale are documented in `../sql/02_golden.sql`. Key departures from naive definitions: "
   "RPC rate is computed within dispositioned calls (not against a different-grain denominator); PTP-kept "
   "rate uses a 14-day window (a 3-day window was tested and rejected — see below).")

code("""con.execute("SELECT * FROM golden_monthly_metrics ORDER BY month").fetchdf()""")

md("### Why the PTP-kept window was widened from 3 to 14 days")

code("""df = con.execute('''
SELECT p.ptp_id,
    (SELECT MIN(ABS(DATE_DIFF('day', pay.event_at, p.promised_date)))
     FROM stg_payments pay WHERE pay.account_id=p.account_id AND pay.is_recognized_recovery) AS min_gap_days
FROM golden_ptp p
''').fetchdf()
print(f"{df['min_gap_days'].isna().mean()*100:.0f}% of PTPs have NO recognized payment on that account at all")
print(df['min_gap_days'].describe())""")

md("Median gap between a PTP and the nearest payment is ~56 days — a ±3 day window returned an implausible <1% "
   "kept rate. Widened to 14 days (documented, industry-typical) for a more honest signal, still only ~3% — "
   "flagged as a data/methodology limitation, not overclaimed as a strong finding.")

md("### Channel comparison — a real, usable signal")

code("""con.execute('''
SELECT channel, COUNT(*) touches, COUNT(DISTINCT account_id) accounts,
    ROUND(100.0*SUM(is_contact::INT)/COUNT(*),1) contact_rate_pct
FROM golden_interactions GROUP BY 1 ORDER BY 1
''').fetchdf()""")

md("**Fact:** Field visits have by far the best contact rate (66%) but are the most expensive channel; "
   "Voice is the largest channel by volume (120K touches) but the weakest (20%) — the biggest lever available.")

md("## Part 4 — Counterfactual: targeting strategy change")

md("The assignment assumes a clean before/after targeting switch. The data doesn't show one — all four "
   "`strategy_version`s ran concurrently at roughly constant monthly volume shares. Stated explicitly rather "
   "than forcing a difference-in-differences design onto data that doesn't support it. Used a matched "
   "cross-sectional comparison instead (stratified by risk_segment to check for Simpson's paradox).")

code("""con.execute('''
WITH worked AS (
    SELECT DISTINCT gi.account_id,
      (SELECT c.campaign_id FROM stg_calls c WHERE c.account_id=gi.account_id ORDER BY c.event_at_ist LIMIT 1) AS first_campaign_id
    FROM golden_interactions gi
),
worked_seg AS (
    SELECT w.account_id, cm.strategy_version, a.risk_segment
    FROM worked w JOIN stg_campaigns cm ON cm.campaign_id=w.first_campaign_id
    JOIN stg_accounts a ON a.account_id=w.account_id
),
recov AS (SELECT account_id, SUM(amount) rec FROM stg_payments WHERE is_recognized_recovery GROUP BY 1)
SELECT ws.strategy_version, ws.risk_segment, COUNT(*) n,
    ROUND(SUM(COALESCE(r.rec,0))/COUNT(*),0) recovery_per_worked_account
FROM worked_seg ws LEFT JOIN recov r ON r.account_id=ws.account_id
GROUP BY 1,2 ORDER BY 1,2
''').fetchdf()""")

md("**Hypothesis, tested and not supported:** recovery-per-worked-account is flat (₹36,474-₹37,147, <2% spread) "
   "across every strategy_version, both overall and within every risk segment — no Simpson's-paradox reversal, "
   "no detectable effect of targeting strategy on recovery.\n\n"
   "**Counterfactual answer:** based on measurable evidence, recovery would very likely have looked "
   "statistically indistinguishable under the old targeting strategy. Limitation: this could mean the change "
   "genuinely didn't matter, or that strategy_version isn't capturing the real targeting change the business "
   "means, or that account self-selection into campaigns (not random) is masking a real effect.")

md("## Part 4 — ₹10 Cr investment recommendation\nFull reasoning, assumptions, and scenario table are in "
   "`../memo/executive_memo.docx`. Summary: recommend a ₹1.5-2 Cr randomized pilot of AI voice automation "
   "(voice is 53% of touches, weakest contact rate at 20%) rather than a full ₹10 Cr commit — under explicit, "
   "clearly-labeled cost assumptions (no cost fields exist in the raw data), full-scale deployment does not "
   "break even in Year 1 or Year 2 against this ~30,000-account portfolio. Confidence is LOW-MEDIUM on the "
   "specific ROI figures, HIGH on the process recommendation (pilot before full commit).")

md("## Summary of classifications\n"
   "| Claim | Class |\n|---|---|\n"
   "| Reported 11% MoM not supported by clean data; real growth ~30% Jan-Jul | **Fact** |\n"
   "| Duplicate/reversed payments inflate naive recovery 6-29%, shrinking over time | **Fact** |\n"
   "| borrower_id corrupted ~98% across all event tables; agents/borrowers dimension tables structurally duplicated | **Fact** |\n"
   "| Vendor mix, portfolio mix, denominator manipulation are drivers | **Ruled out (strong evidence against)** |\n"
   "| Contact rate flat; PTP rate & recovery/account are the real movers | **Fact** |\n"
   "| Targeting strategy version affects recovery | **Hypothesis, not supported** |\n"
   "| AI voice automation ROI at full ₹10 Cr scale | **Hypothesis (assumption-based, low-medium confidence)** |")

nb['cells'] = cells
nbf.write(nb, 'analysis.ipynb')
print("notebook written")