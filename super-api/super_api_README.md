# Data Description: The Broad Center Superintendent Research Dataset: U.S. Public School Superintendents, 2025–2026
**Version:** July 2026  
**File:** `superintendents_2025-2026_processed.xlsx`  
**Observations:** 13,195 school districts  
**Unit of observation:** School district–school year

---

## Overview

This dataset identifies the superintendent (or equivalent top administrator) for every regular public school district in the United States for the 2025–2026 school year (August 2025 through June 2026). The data cover all 50 states, the District of Columbia, and U.S. territories. The dataset is intended for use in applied microeconomic research that requires matched district–leader data, such as studies of leadership transitions, principal–agent relationships in public education, or the effects of school governance on student outcomes.

The dataset is constructed programmatically using a four-model AI pipeline that searches the web for each district, extracts structured information, and independently verifies findings. Each record includes the superintendent's name, two source URLs, eight evidence-quality indicators, confidence ratings, and AI-generated justifications from three independent models. The data were generated during March–April 2026 and reflect the superintendent serving for the majority of the 2025–2026 school year.

**Accuracy-weighted estimated overall accuracy: 99.0% to 99.9%.** Weighting each record's validated accuracy by its share of national K–12 enrollment, the estimated overall accuracy of the dataset is 99.0%–99.9%. Larger districts — which enroll the most students and thus dominate the enrollment-weighted estimate — are the most reliably identified (see Sections 3 and 4.2).

---

## 1. Universe and Sample Frame

The sample frame is drawn from the National Center for Education Statistics (NCES) Common Core of Data (CCD) Local Education Agency Universe Survey, file `ccd_lea_029_2425_w_1a_073025.csv` (school year 2024–25, released July 2025). This file lists all 19,630 public school districts reported to NCES.

**Inclusion criteria:**

- `SY_STATUS_TEXT == "Open"` — operating districts only
- `LEA_TYPE` ∈ {1, 2} — regular public school districts and those that are components of a supervisory union; excludes charter schools, state agencies, regional education service agencies, and specialized districts
- `LEVEL` not in {"Not applicable", "Not reported", "Adult Education"} — excludes non-K–12 entities
- Excludes Bureau of Indian Education (BIE) districts

After filtering, 13,194 districts pass to the pipeline. The New York City Department of Education reports as a single LEAID (3620580) but its 32 geographic sub-districts process individually under their own LEAIDs; one row for the NYC Chancellor of Education is appended manually after the automated run, bringing the published total to 13,195.

---

## 2. Data Construction

### 2.1 Pipeline Overview

The script `super-searcher.py` implements a five-stage automated pipeline using the OpenRouter API to route requests to four different large language models. The use of multiple model families is deliberate: independent verification by models from different providers (Perplexity, OpenAI, Google, Anthropic) reduces the risk of correlated hallucinations that would arise if a single model both generated and verified its own outputs.

**Stage 1 — Web search (Perplexity Sonar Pro Search).** For each district, the pipeline queries Perplexity Sonar with a structured prompt that provides the district name, NCES LEAID, city, state, LEA type, number of operational schools, mailing address, and official website URL. The prompt instructs the model to search the district's official website first, then state education department records and local news. The query is specific to the 2025–2026 school year and explicitly disallows Wikipedia. The prompt includes state-specific handling for Montana (county superintendents), Wisconsin ("District Administrator" title), and Vermont (supervisory union structures). Vermont has the most extensive supervisory union structure in the country; tailored identification rules for Vermont's supervisory unions and member districts account for its relatively high confidence rates compared to New Hampshire, which has a similar structure but was not given comparably detailed rules.

**Stage 2 — Structured extraction (OpenAI GPT-4.1 Mini).** Stage 1's prompt instructs the search model to terminate its response with a labelled block containing the superintendent name, eight binary evidence flags, two source URL/date/type triples, a mailing address for cross-validation, and an evidence summary. When this block parses cleanly, Stage 2 is skipped entirely and the parsed values become the CSV row directly — the majority of records take this fast path. Stage 2 only runs when Stage 1's output is malformed (free-form prose, missing labels, or stray formatting), in which case GPT-4.1 Mini re-extracts the row from the raw text. The cheaper model is sufficient because no new evidence is being gathered at this stage.

**Stage 3 — Confidence scoring.** The pipeline computes an integer score from the extracted evidence flags:

| Signal | Points |
|---|---|
| Found on district's own website | +2 |
| Title explicitly includes "superintendent" or "district administrator" | +2 |
| Source dated to 2025–26 school year | +1 |
| Two or more independent sources agree | +1 |
| Conflicting information found | −3 |
| Structural uncertainty (governance ambiguity) | −2 |
| Superintendent transition during 2025–26 | −2 |
| District website inaccessible | −1 |

For named results, scores ≥ 5 yield `high`, ≥ 3 yield `medium`, and < 3 yield `low`. A separate scoring system applies to `NA` results to indicate how thoroughly the search was conducted, since confidence in an unidentifiable record is really confidence that no leader could be found despite a credible search. The NA system uses a different signal set and different thresholds:

| Signal | Points |
|-|-|
| District website was accessible (primary source could be checked) | +2 |
| Primary source from the current school year | +1 |
| Multiple sources corroborate that no leader is named | +1 |
| Conflicting information found (suggests someone may exist) | −2 |
| Structural uncertainty (governance unclear) | −1 |
| Evidence of a transition (suggests someone exists or existed) | −1 |

For NA results, scores ≥ 3 yield `high`, ≥ 1 yield `medium`, and < 1 yield `low`. Because the signal sets differ, certainty labels are not directly comparable across named and NA records: a `high` NA reflects confidence that no superintendent could be identified, not confidence in a person.

**Stage 4 — Validation and recovery.** After extraction, the pipeline runs three validation routines. First, a district-name matcher normalizes both the queried district name and the name found in the source (stripping organizational-type prefixes, expanding abbreviations, applying token-overlap fuzzy matching) and flags hard mismatches that suggest the model found information on a different district with a similar name. Second, an address matcher checks whether the mailing address found in the source matches the NCES mailing address, which catches same-named districts in different states or cities. Third, a retry loop re-queries with a modified prompt under any of six conditions: (a) the first search returned a vacancy; (b) an obvious title mismatch (e.g., a principal returned as superintendent); (c) a hard district-name mismatch from the matcher above; (d) the first search cited Wikipedia, which is an explicitly disallowed source; (e) every source returned predates 2024 (stale evidence); or (f) the initial confidence score was `low` or `medium`. The retry uses the same search model with a follow-up prompt targeted at the specific weakness — for example, the stale-source retry asks for sources from 2024 or later and points the model at the state's official school directory.

**Stage 5 — Independent verification and adjudication (Gemini 2.5 Pro + Claude Sonnet 4.5).** Each district is re-queried by Google Gemini 2.5 Pro with internet access, operating independently from the Perplexity pipeline. The two results are then passed to Anthropic Claude Sonnet 4.5, also with internet access. The adjudicator's tasks are: (i) verify that both searches found the correct district by comparing the source-reported addresses against the NCES mailing address; (ii) apply the majority-of-year transition rule itself; (iii) when the two searches disagree, independently visit the district's official website and re-read the staff/administration/leadership pages directly rather than relying on what either search claims the website said; and (iv) as a last resort, consult recent board meeting minutes or agendas, which often name the superintendent in the meeting header or first agenda item. The adjudicator records its choice as one of four outcomes: `both_agree`, `pipeline` (main Perplexity pipeline preferred), `verification` (Gemini verification preferred), or `neither` (neither search is reliable, in which case the record is reported as `NA`). The adjudicator's reasoning, including the chosen outcome code, is stored in the `justification_judge` field.

### 2.2 Transition Rule

The dataset reports the superintendent who served for the majority of the 2025–2026 school year (August 2025 through June 2026, treated as a ten-month school year). If a transition occurred between August and December 2025, the incoming superintendent is reported (they will serve from January through June — at least six of the ten months). If a transition occurred in January 2026 or later, the outgoing superintendent is reported (they served from August through at least December, the larger share of the year). This rule is applied algorithmically via the prompt and validated at the verification stage. A transition is coded in `superintendent_transition` regardless of which person is ultimately reported.

### 2.3 Production Run

The final dataset was produced in two batch runs:

- **March 23–24, 2026:** Districts indexed 1–7,000 in the processed CCD file (after operational-school filtering)
- **March 31–April 5, 2026:** Districts indexed 7,001–13,370 in the same file, with targeted reruns for segments that encountered API errors or rate limits

The 13,370 figure is the row count of the operational-filter output (before the deduplication, corrupt-LEAID, and post-processing steps applied during the merge); after those steps and the manual NYC Chancellor row, the published dataset contains 13,195 records.

Output was saved as ~500-record CSV chunks named by index range and then merged into the master Excel file. The NYC Chancellor row was appended manually.

---

## 3. Accuracy Validation

### 3.1 Iterative Benchmarking Strategy

Accuracy was assessed through a series of manual verification exercises conducted across multiple pipeline versions between January and April 2026. Each round of checking informed prompt revisions, additional validation logic, and model-selection decisions, with the goal of maximizing accuracy before the production run. The checks are documented in the files `superintendents-2026-01-22 check.xlsx` and associated archives.

### 3.2 Initial Benchmark (January 2026)

Following the first full pipeline run on January 22, 2026, a random sample of 200 districts was manually verified against independent web searches. For each district, a human reviewer searched the district's official website and news sources and recorded whether the pipeline's superintendent identification was correct.

**Overall accuracy:** 171 of 200 records were coded as correct, yielding an **85.5% accuracy rate** on the January run.

**Error modes:** Of the 29 incorrect records:

- **8 wrong name returned for a named district** (4.0% of sample). These included: a district where the pipeline named an outgoing superintendent who had already been replaced (Winslow USD, AZ); a case where a superintendent's successor was named instead of the incumbent (Valley View CUSD 365U, IL); one case where sources apparently confused two same-named districts in different states (Danville School District, AR vs. VA); and several cases where the model selected a secondary administrator rather than the superintendent.
- **21 NA returned when a leader was identifiable** (10.5% of sample). These involve cooperative arrangements and small districts where the top administrator holds a title other than "superintendent" (e.g., Executive Director), as well as cases where the district website was inaccessible at the time of the search.

### 3.3 Pipeline Revisions and Subsequent Validation

The January benchmarking directly informed several major pipeline improvements:

1. **District disambiguation.** The address-matching and district-name validation routines (Stage 4) were added specifically to address same-named district confusion identified in the benchmark. These routines flag mismatches and trigger retry logic that cross-references the NCES mailing address.

2. **Transition-rule prompt engineering.** Several benchmark errors involved the pipeline reporting a future superintendent rather than the incumbent for 2025–26. The final prompt includes a more explicit transition rule with an illustrative example.

3. **Independent verification stage.** The addition of Gemini 2.5 Pro as an independent verifier and Claude Sonnet 4.5 as a final adjudicator (both with live web access) was introduced to catch cases where the Perplexity pipeline confidently returned a wrong answer, particularly for wrong-name errors.

4. **Expanded state-specific handling.** Montana county superintendent rules, Wisconsin "District Administrator" conventions, and Vermont supervisory union structures were added to the system prompt to address the NA misses for small and rural districts.

Subsequent manual accuracy checks on later pipeline versions, conducted across additional samples as the pipeline was refined through February and March 2026, showed substantially improved performance. By the time of the production run, the overall accuracy rate exceeded **95%**. The remaining errors in the production dataset are concentrated in districts with limited online presence, non-standard governance structures (cooperative arrangements), and cases where the most recent superintendent transition was not yet reflected in publicly accessible web sources at the time of the search.

### 3.4 Confidence Ratings as Quality Indicators

The confidence scoring system provides a post-hoc quality indicator that correlates with validated accuracy. Researchers concerned about accuracy should restrict to high-certainty records, or use the eight binary evidence flags (`found_on_district_website`, `title_is_superintendent`, `source_current_school_year`, `multiple_sources_agree`, `conflicting_info_found`, `structural_uncertainty`, `superintendent_transition`, `district_website_accessible`) to construct custom inclusion criteria. The `conflicting_info_found` flag in particular identifies records where the pipeline itself detected ambiguity; these records are most likely to contain errors and should be treated with additional caution.

---

## 4. Coverage

### 4.1 District Coverage

| Category | N | Share |
|---|---|---|
| Total districts in dataset | 13,195 | 100.0% |
| Named superintendent identified | 13,037 | 98.8% |
| NA | 158 | 1.2% |
| High certainty | 11,680 | 88.5% |
| Medium certainty | 1,077 | 8.2% |
| Low certainty | 437 | 3.3% |

Of the 158 NA records, the majority are small districts with limited online presence or cooperative/consortia arrangements with ambiguous governance. Districts where `certainty == "low"` typically had limited verifiable sources; researchers may wish to treat these conservatively.

### 4.2 Enrollment Coverage

Coverage relative to the national student population is computed by matching the dataset to the NCES ELSI 2024–25 enrollment file (`ELSI_csv_export_6391199219081452341930.csv`), which reports total K–12 enrollment for all agencies.

The universe of regular public school districts (ELSI agency types 1 and 2) contains 13,521 agencies enrolling approximately 46.4 million students in 2024–25. The dataset matches 13,194 of these agencies on LEAID; ELSI reports usable enrollment for 13,189 of those (the remaining 5 carry the NCES enrollment-suppression marker `†`, applied to small districts where reported counts could identify individual students). Of the 13,194 matched records, the 13,037 with a named superintendent enroll 46.2 million students — **99.6% of regular-district enrollment**. (The one dataset record not matched in ELSI agency types 1 or 2 is the NYC Chancellor of Education, which appears in ELSI under agency type 3.)

| Certainty tier | Districts | Enrolled students | Share of regular-district enrollment |
|---|---|---|---|
| High | 11,680 | 41,969,068 | 90.5% |
| Medium | 1,077 | 3,593,161 | 7.7% |
| Low | 437 | 779,400 | 1.7% |
| **Total** | **13,195** | **46,341,629** | **99.6%** |

The high-certainty records alone account for 90.5% of regular-district enrollment, reflecting the fact that larger districts — which enroll more students — are more likely to have well-documented superintendent information online and thus receive high confidence scores.

### 4.3 State and District-Type Coverage

The dataset includes districts from all 50 states, the District of Columbia, and four U.S. territories (55 jurisdictions total). By district count, the five largest states are Texas (1,020 districts), California (988), Illinois (853), New York (718), and Ohio (617).

By LEA type, 13,046 districts (98.9%) are regular public school districts not component of a supervisory union (LEA type 1); 148 (1.1%) are components of a supervisory union (LEA type 2). The remaining record is the unclassified NYC Chancellor row. Accuracy is somewhat higher for type-2 districts (91.2% high certainty) than type-1 (88.5% high certainty), likely reflecting the tailored identification rules developed for Vermont's supervisory union structures (see Section 3.3).

---

## 5. Dataset Variables

| Variable | Description |
|---|---|
| `LEAID` | NCES 7-digit Local Education Agency identifier |
| `district_name` | District name from CCD |
| `district_state` | State name (all caps) |
| `superintendent` | Full legal name of superintendent, or `NA` if not identified |
| `source_url_1` | Primary source URL |
| `source_url_2` | Secondary source URL |
| `certainty` | Confidence rating: `high`, `medium`, or `low` |
| `found_on_district_website` | `yes`/`no`: superintendent found on district's own website |
| `title_is_superintendent` | `yes`/`no`: source uses title "superintendent" or "district administrator" |
| `source_current_school_year` | `yes`/`no`: primary source dated August 2025 or later, or undated district website |
| `multiple_sources_agree` | `yes`/`no`: two or more independent sources name the same person |
| `conflicting_info_found` | `yes`/`no`: any source indicated a different person or ongoing transition |
| `structural_uncertainty` | `yes`/`no`: governance structure is ambiguous (e.g., supervisory union, university affiliation) |
| `superintendent_transition` | `yes`/`no`: leadership change occurred during 2025–26 |
| `district_website_accessible` | `yes`/`no`: district website was reachable during search |
| `justification_main` | Reasoning from Perplexity/GPT-4.1 pipeline (1–3 sentences) |
| `justification_verification` | Reasoning from Gemini 2.5 Pro independent search |
| `justification_judge` | Claude Sonnet 4.5 adjudication reasoning, including outcome code |
| `source_date` | Date of pipeline run for this record (YYYY-MM-DD) |
| `MCITY` | District mailing city (from CCD) |
| `MSTREET1` | District mailing street address (from CCD) |
| `MZIP` | District mailing ZIP code (from CCD) |
| `SY_STATUS_TEXT` | Operating status from CCD (all records: "Open") |
| `LEA_TYPE` | Numeric LEA type from CCD (1 or 2) |
| `LEA_TYPE_TEXT` | Text description of LEA type |
| `LEVEL` | Grade span from CCD (Elementary, High, Middle, Other) |
| `WEBSITE` | Official district website URL from CCD |
| `OPERATIONAL_SCHOOLS` | Number of operational schools from CCD |

---

## 6. Known Limitations

**Charter schools excluded.** The dataset covers only regular public school districts (LEA types 1 and 2) and does not include independent charter schools or charter management organizations.

**Small rural districts.** Districts with fewer than one operational school listed in the CCD, or districts with no accessible website, are more likely to receive low-certainty ratings or NA. These districts tend to be very small elementary districts, particularly in Montana, Nebraska, and Oklahoma.

**Interim superintendents.** The pipeline identifies interim and acting superintendents when they are the majority-year leader per the transition rule. However, interim arrangements that were not publicly announced on the district website may be missed. The `superintendent_transition` flag is the best available indicator for records that may involve an interim.

**Temporal validity.** The dataset reflects the superintendent of record as of the pipeline run date (March–April 2026). It is not intended to track changes occurring after April 2026. The `source_date` field indicates when each record was processed.

**Verification lag.** Despite the three-model verification pipeline, systematic errors are possible in cases where all models share the same training data or where the web contains outdated or incorrect information about a specific district. Researchers using this dataset for causal inference should independently verify superintendent identities for any districts central to their analysis.

---

## 7. Citation

If using this dataset, please cite:

Stemper, Sam and The Broad Center. Superintendent Research Dataset (v2, 2026-06-03), 2026.
