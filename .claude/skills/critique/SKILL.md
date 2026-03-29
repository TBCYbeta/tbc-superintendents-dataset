---
name: critique
description: Run the disambiguation critic on results. Use when user says "critique", "evaluate results", "audit predictions", "check quality", or "review the output".
argument-hint: "[CSV file path] [optional: --sample N | --suspect-only | --case 'Name']"
allowed-tools: ["Read", "Write", "Bash", "Task"]
---

# Critique Disambiguation Results

## Overview

Run the adversarial disambiguation-critic agent against output results. The critic evaluates each case's reasoning against the 10-point audit checklist without changing any results.

## Modes

### Full Batch Review
Review all cases in an output file:
```
/critique Cameron_01202026/cross_state_matches_output_merged.csv
```

### Sample Review
Review a random sample of N cases:
```
/critique Cameron_01202026/cross_state_matches_output_merged.csv --sample 20
```

### Single Case
Drill into one specific case:
```
/critique Cameron_01202026/cross_state_matches_output_merged.csv --case "Lawrence Kapugia"
```

### Suspect-Only
Focus on high-risk cases (common names + high confidence, or uncertain predictions):
```
/critique Cameron_01202026/cross_state_matches_output_merged.csv --suspect-only
```

## Steps

1. **Load results:** Read the CSV file and parse prediction, confidence, reasoning, evidence_urls for each case.

2. **Filter** (based on mode):
   - `--sample N`: Random sample of N cases
   - `--suspect-only`: Filter to cases matching risk criteria:
     - Very common names with "high" confidence "same"
     - Any "uncertain" predictions
     - Any predictions with empty evidence_urls
     - Any predictions where reasoning is very short (< 200 chars)
   - `--case "Name"`: Single case by name
   - Default: all cases

3. **Run critic agent:** For each case, apply the 10-point audit checklist from `.claude/agents/disambiguation-critic.md`. Use parallel Task agents for batches (3 at a time).

4. **Generate report:** Save to `quality_reports/critique_YYYY-MM-DD_[filename].md`

5. **Present summary:**
   - Distribution: CONFIRMED / PLAUSIBLE / QUESTIONABLE / SUSPECT
   - Cases recommended for re-run
   - Systematic issues found
   - Overall quality assessment

## Risk Heuristics for --suspect-only

Very common names (flag if prediction = "same" with high confidence):
- John, James, Robert, Michael, William, David, Richard, Joseph, Thomas, Charles
- Smith, Johnson, Williams, Brown, Jones, Garcia, Miller, Davis, Rodriguez, Martinez

Short reasoning (< 200 chars) with high confidence: likely insufficient analysis.

Empty evidence_urls with non-uncertain prediction: no supporting evidence cited.

## Example Output

```
Critic Report: cross_state_matches_output_merged.csv
Reviewed: 20 / 1512 cases (sample)

CONFIRMED:  14 (70%) — reasoning sound, evidence strong
PLAUSIBLE:   4 (20%) — minor gaps, probably correct
QUESTIONABLE: 2 (10%) — significant concerns
SUSPECT:     0 (0%)  — no major flaws detected

Recommended Re-Runs:
  - Michael Brown (Springfield → Lincoln): common name, only 1 Tier 2 source
  - David Williams (Fairview → Lakewood): no archive check for 2009 records

Systematic Issues:
  - 3/20 cases did not verify full name at both districts
```
