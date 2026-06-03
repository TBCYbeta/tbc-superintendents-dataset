import os
import json
import csv
from dataclasses import dataclass
from datetime import date, datetime
import random
import time
import unicodedata
from typing import Optional
import re

import requests

# Note: Restricts to LEA_TYPE 1 and 2 (public schools), excludes "Not applicable" and "Not reported" levels,
# and excludes Bureau of Indian Education districts.
# Reminder to self: manually add NYC Chancellor row after running the script.

# Optionally hardcode your OpenRouter API key here instead of using a file or
# env var. For example: HARDCODED_API_KEY = "sk-or-v1-..."
HARDCODED_API_KEY: Optional[str] = None

# Run mode: "all" to process every open district in ccd_processed.csv,
# or "sample" to process a random subset of size SAMPLE_SIZE.
RUN_MODE = "sample"  # "all" or "sample"

# When RUN_MODE == "sample", number of districts to process.
SAMPLE_SIZE = 10

# Fixed random seed so sampling is reproducible for a given seed. Note previously used seed was 42, 99, 24, 70, 1, 2, 3, 4, 5, 6.
RANDOM_SEED = 7


ALLOWED_LEAIDS: frozenset[str] = frozenset()

# Model to call via OpenRouter for web-search-style research (step 1).
OPENROUTER_MODEL_ID_STEP1 = "perplexity/sonar-pro-search"

# Search model for retries (step 1 retry). Same quality as step 1 — a weaker
# model cannot recover what the stronger one missed.
OPENROUTER_MODEL_ID_RETRY = "perplexity/sonar-pro-search"

# Model to call via OpenRouter for structured extraction / CSV formatting (step 2).
OPENROUTER_MODEL_ID_STEP2 = "openai/gpt-4.1-mini" # Using a cheaper model sufficient for this task to save money.

# Independent verification uses a different model family to avoid
# correlated hallucinations with the Perplexity pipeline.
OPENROUTER_MODEL_ID_VERIFY = "google/gemini-2.5-pro:online"

# Final adjudicator uses a third model family (Anthropic) to reconcile
# pipeline and verification results, with web access for independent checks.
OPENROUTER_MODEL_ID_ADJUDICATE = "anthropic/claude-sonnet-4.5:online"

# Reusable HTTP session for OpenRouter API calls (connection pooling).
_api_session: Optional[requests.Session] = None

# Cached API key (populated on first call to get_api_key()).
_cached_api_key: Optional[str] = None


def _get_api_session() -> requests.Session:
	"""Return a reusable requests.Session for OpenRouter API calls."""
	global _api_session
	if _api_session is None:
		_api_session = requests.Session()
	return _api_session


def _api_post_with_retry(
	url: str, headers: dict, body: dict,
	max_retries: int = 3, base_delay: float = 2.0, timeout: int = 60,
) -> requests.Response:
	"""POST to an API with exponential backoff on transient errors (429, 500, 502, 503, 504)."""
	session = _get_api_session()
	for attempt in range(max_retries + 1):
		try:
			response = session.post(url, headers=headers, data=json.dumps(body), timeout=timeout)
			if response.status_code in (429, 500, 502, 503, 504) and attempt < max_retries:
				delay = base_delay * (2 ** attempt)
				print(f"  HTTP {response.status_code}; retrying in {delay:.0f}s (attempt {attempt + 1}/{max_retries})...")
				time.sleep(delay)
				continue
			return response
		except (requests.exceptions.ConnectionError, requests.exceptions.Timeout) as e:
			if attempt < max_retries:
				delay = base_delay * (2 ** attempt)
				print(f"  Connection error: {e}; retrying in {delay:.0f}s (attempt {attempt + 1}/{max_retries})...")
				time.sleep(delay)
				continue
			raise
	return response  # unreachable, but satisfies type checker


def preprocess_ccd_districts() -> None:
	"""Read the CCD districts CSV and write a slimmed-down ccd_processed.csv.

	Input file locations tried (in order):
	1. Current working directory
	2. Directory containing this script
	3. User's home directory

	The output file ccd_processed.csv is always overwritten and contains only
	the columns: SCHOOL_YEAR, STATENAME, LEA_NAME, LEAID, MCITY, MSTREET1,
	MZIP, SY_STATUS_TEXT, LEA_TYPE, LEA_TYPE_TEXT, LEVEL.
	"""

	input_filename = "ccd_lea_029_2425_w_1a_073025.csv"
	possible_paths = [
		os.path.join(os.getcwd(), input_filename),
		os.path.join(os.path.dirname(os.path.abspath(__file__)), input_filename),
		os.path.join(os.path.expanduser("~"), input_filename),
	]

	input_path: Optional[str] = None
	for path in possible_paths:
		if os.path.exists(path):
			input_path = path
			break

	if input_path is None:
		print(
			"Warning: CCD input CSV 'ccd_lea_029_2425_w_1a_073025.csv' not found in "
			"current directory, script directory, or home directory. Skipping "
			"ccd_processed.csv generation."
		)
		return

	output_path = os.path.join(os.getcwd(), "ccd_processed.csv")
	fieldnames = ["SCHOOL_YEAR", "STATENAME", "ST", "LEA_NAME", "LEAID", "MCITY", "MSTREET1", "MZIP", "SY_STATUS_TEXT", "LEA_TYPE", "LEA_TYPE_TEXT", "LEVEL", "WEBSITE", "OPERATIONAL_SCHOOLS"]

	with open(input_path, "r", newline="", encoding="utf-8") as infile, open(
		output_path,
		"w",
		newline="",
		encoding="utf-8",
	) as outfile:
		reader = csv.DictReader(infile)
		writer = csv.DictWriter(outfile, fieldnames=fieldnames)
		writer.writeheader()
		for row in reader:
			out = {name: row.get(name, "") for name in fieldnames}
			raw_id = out.get("LEAID", "").strip()
			if raw_id and raw_id.isdigit():
				out["LEAID"] = raw_id.zfill(7)
			writer.writerow(out)

	print(f"Wrote processed CCD districts to {output_path}")


def get_api_key() -> str:
	"""Return the OpenRouter API key (cached after first read).

	Priority order:
	1. Text file named `openrouter_key.txt` in the same folder as this script.
	2. Environment variable `OPENROUTER_API_KEY`.
	3. `HARDCODED_API_KEY` constant above.
	"""
	global _cached_api_key
	if _cached_api_key is not None:
		return _cached_api_key

	# 1. Try local text file next to this script
	script_dir = os.path.dirname(os.path.abspath(__file__))
	key_file_path = os.path.join(script_dir, "openrouter_key.txt")
	if os.path.exists(key_file_path):
		with open(key_file_path, "r", encoding="utf-8") as f:
			file_key = f.read().strip()
			if file_key:
				_cached_api_key = file_key
				return _cached_api_key

	# 2. Try environment variable
	env_key = os.environ.get("OPENROUTER_API_KEY")
	if env_key:
		_cached_api_key = env_key
		return _cached_api_key

	# 3. Try hardcoded key
	if HARDCODED_API_KEY:
		_cached_api_key = HARDCODED_API_KEY
		return _cached_api_key

	raise RuntimeError(
		"No OpenRouter API key found. Create an 'openrouter_key.txt' file "
		"next to this script, set the OPENROUTER_API_KEY environment variable, "
		"or set HARDCODED_API_KEY in the script."
	)


def ask_superintendent_with_openrouter(
	district: str, state_name: str = "", lea_id: str = "", city: str = "",
	lea_type_text: str = "", state_abbr: str = "", website: str = "",
	operational_schools: str = "", mailing_address: str = "",
) -> tuple[str, list[dict]]:
	"""Step 1: Use OpenRouter model to research the superintendent.

	Returns (answer_text, messages) where messages is the full conversation
	history (system + user + assistant) so it can be continued in a retry.
	"""
	if not state_name and "," in district:
		state_name = district.split(",", 1)[1].strip()

	api_key = get_api_key()

	district_desc = f"{district}"
	# Extract parenthetical qualifier (often a county) for disambiguation.
	# Skip purely numeric values (district IDs like "(4478)").
	county_match = re.search(r"\(([^)]+)\)\s*$", district.split(",")[0])
	county_hint = ""
	if county_match and not county_match.group(1).strip().isdigit():
		county_hint = f" (county: {county_match.group(1)})"
	if city and city.upper() not in district.upper():
		district_desc += f" (city: {city})"
	if county_hint:
		district_desc += county_hint
	if lea_id:
		district_desc += f" [NCES LEAID {lea_id}]"
	if lea_type_text:
		district_desc += f" (type: {lea_type_text})"
	if operational_schools and operational_schools not in ("", "0"):
		district_desc += f" [{operational_schools} school(s)]"
	if mailing_address:
		district_desc += f" (NCES mailing address: {mailing_address})"

	state_search = state_name
	if state_abbr:
		state_search = f"{state_name} ({state_abbr})"

	website_hint = ""
	if website:
		website_hint = (
			f" The district's official website is {website}. "
			f"Visit this URL directly and check its staff, administration, leadership, "
			f"or about pages for superintendent information before searching elsewhere."
		)

	today_iso = date.today().isoformat()
	question = (
		f"Today is {today_iso}. "
		f"Who is the superintendent of {district_desc} in {state_search} for the 2025–2026 school year "
		f"(Aug 2025 – Jun 2026)? We want the person who served (or will serve) for the majority "
		f"of that school year. Search the district website first, then {state_search} state "
		"records and news. "
		f"IMPORTANT: This district is in {state_search} — do NOT confuse it with any "
		f"same-named district in a different state. Verify that the website and sources you "
		f"find are for the {state_search} district, not a similarly named district elsewhere. "
		f"Do not use Wikipedia.{website_hint}"
	)

	state_convention = (
		"- In many districts (especially small or rural districts in any state), the "
		"superintendent equivalent is titled 'District Administrator' or 'School District "
		"Administrator.' This is especially common in Wisconsin, where 'District Administrator' "
		"is the standard title used in place of 'Superintendent.' If the district has no one "
		"with the title 'superintendent' but does have a 'District Administrator' as the top "
		"district leader, report that person. Search for both 'superintendent' and 'district "
		"administrator' when looking for this district's leader.\n"
	)

	mt_county_rule = ""
	if state_abbr and state_abbr.upper() == "MT":
		mt_county_rule = (
			"- MONTANA COUNTY SUPERINTENDENT: In Montana, very small elementary districts "
			"(especially those with few students or only one school) often do NOT have their "
			"own superintendent. Instead, the elected County Superintendent of Schools serves "
			"as their superintendent. If you cannot find a superintendent on the district's own "
			"website, check the county government website (e.g., <county>mt.gov or "
			"<county>countymt.gov under 'superintendent of schools' or 'education') to find "
			"the county superintendent who oversees this district. Report the county "
			"superintendent if no district-level superintendent exists.\n"
		)

	system_msg = (
		"You are a researcher identifying US school district superintendents.\n\n"
		"Rules:\n"
		"- Find the superintendent for 2025–2026.\n"
		"- In very small or single-school districts, the top leader sometimes holds a combined title such as "
		"'Superintendent/Principal.' If someone has 'superintendent' in their title (even combined), report them.\n"
		"- If the district has NO superintendent or equivalent — i.e. the highest position is principal, "
		"head of school, director, CEO, or business manager with no superintendent title — report UNKNOWN and explain in "
		"UNKNOWN_REASON that the district's highest role is not superintendent.\n"
		"- The district's official website is presumed current and ALWAYS takes precedence over state "
		"directories, news articles, and all other sources. If the district website lists person X as "
		"superintendent but a state directory or news article lists person Y, report person X. "
		"State directories are often months out of date. No Wikipedia.\n"
		"- If the district website has a staff or employee directory, check "
		"ALL pages (page 2, page 3, etc.) — the superintendent may not appear on the first page. "
		"If the directory has a search or filter function, use it to search for 'superintendent' "
		"rather than only browsing pages manually.\n"
		"- If named superintendent in 2023–24 with no departure news, report that name (avg tenure 5–6 yrs).\n"
		"- If the superintendent is on leave, suspended, or removed, report the acting/interim superintendent.\n"
		"- TRANSITION RULE: We want the person who served (or will serve) as superintendent for the "
		"MAJORITY of the 2025–26 school year (Aug 2025 – Jun 2026). If a transition occurred between "
		"August and December 2025, report the NEW superintendent (they will serve the majority of the "
		"year). If a transition occurred in January 2026 or later, report the EARLIER superintendent "
		"(they served the majority of the year). Note any transition details in EVIDENCE_SUMMARY. "
		"If a superintendent served from the start of the school year but then departed, retired, or the "
		"position became vacant partway through, still report that person if they served the majority "
		"(Aug–Jan = 6+ months of the 10-month school year). A current vacancy, ongoing superintendent "
		"search, or retirement does NOT mean UNKNOWN — if someone already served most of the year, "
		"report their name. Example: if a superintendent retired December 31 and no replacement has "
		"been named, report the retired superintendent (they served Aug–Dec, 5 months of the year, "
		"which is the majority if no one else served longer).\n"
		"- Only use UNKNOWN when the full weight of evidence "
		"suggests there is no superintendent or highest-ranking district official — it should be rare.\n"
		"- For SUPERINTENDENT_FULL_NAME: provide exactly one clean full legal name (e.g. 'Jane Smith'). "
		"Always use the person's full legal name, not a nickname or shortened form "
		"(e.g. 'Timothy' not 'Tim', 'Robert' not 'Bob', 'William' not 'Bill'). "
		"Do not include quotation marks, parentheses, or special characters other than "
		"hyphens and periods in the name. "
		"Do NOT include quoted nicknames (e.g. write 'Andrea Davis' not 'Andrea \"Andre\" Davis'), "
		"qualifiers, or conditional language. Never output a name combined with UNKNOWN "
		"(e.g. 'Roberto Euresti or UNKNOWN if appointment did not take effect' is wrong — "
		"just write 'Roberto Euresti'). Report only ONE name — the person who served the majority of the year.\n"
		"- If sources conflict on who the superintendent is, the district's own official website always "
		"takes precedence. If the district website is inaccessible, prefer the most recent evidence.\n"
		"- DISTRICT VERIFICATION: When an NCES mailing address is provided, verify you have the correct "
		"district by checking the address in the footer or contact page of the district website. If the "
		"website's address or zip code does not match the NCES mailing address, you may have found "
		"a different district with a similar name. Report the mailing address you find on the "
		"district website in the DISTRICT_MAILING_ADDRESS field below.\n"
		"- For lab schools and university-affiliated schools, only report someone whose primary role is "
		"leading the K-12 school itself (e.g., 'Head of School', 'School Director', 'Executive Director', "
		"'School Principal'). Any person whose title includes 'Dean' of a university college or department "
		"is university personnel and must be excluded, even if they have administrative authority over the school.\n"
		f"{state_convention}"
		f"{mt_county_rule}"
		"End with this block (answer every field):\n"
		"DISTRICT_CONFIRMED: <exact official district name from your sources, not from the query>\n"
		"SUPERINTENDENT_FULL_NAME: <name or UNKNOWN>\n"
		"FOUND_ON_DISTRICT_WEBSITE: <yes|no> — was this name found on the district's own official website?\n"
		"TITLE_IS_SUPERINTENDENT: <yes|no> — does the source explicitly use the title 'superintendent' or 'district administrator' for this person? Answer 'no' if their title is only principal, director, head of school, CEO, business manager, or similar.\n"
		"SOURCE_CURRENT_SCHOOL_YEAR: <yes|no> — is the primary source clearly from the 2025–26 school year (dated Aug 2025 or later, or an undated district website presumed current)?\n"
		"MULTIPLE_SOURCES_AGREE: <yes|no> — did two or more independent sources name the same person as superintendent?\n"
		"CONFLICTING_INFO_FOUND: <yes|no> — did any source suggest a different person, an ongoing transition, a recent resignation, or any disagreement about who the superintendent is?\n"
		"STRUCTURAL_UNCERTAINTY: <yes|no> — is it unclear whether the correct leader is at the school level or a higher governance level (e.g., supervisory union, tribal school system, university affiliation)?\n"
		"SUPERINTENDENT_TRANSITION: <yes|no> — is there evidence of a superintendent change during the 2025–26 school year (Aug 2025 – Jun 2026), such as one person leaving and another starting?\n"
		"DISTRICT_WEBSITE_ACCESSIBLE: <yes|no> — were you able to access and read the district's website?\n"
		"DISTRICT_MAILING_ADDRESS: <mailing address from district website footer or contact page, or blank if not found>\n"
		"EVIDENCE_SUMMARY: <1–2 sentences explaining what you found and any concerns>\n"
		"UNKNOWN_REASON: <if UNKNOWN, why; else blank>\n"
		"SOURCE_URL_1: <url or blank>\n"
		"SOURCE_TYPE_1: <district_website|government|news|other|none>\n"
		"SOURCE_DATE_1: <YYYY-MM or undated>\n"
		"SOURCE_URL_2: <url or blank>\n"
		"SOURCE_TYPE_2: <district_website|government|news|other|none>\n"
		"SOURCE_DATE_2: <YYYY-MM or undated>"
	)

	url = "https://openrouter.ai/api/v1/chat/completions"
	headers = {
		"Authorization": f"Bearer {api_key}",
		"Content-Type": "application/json",
		"HTTP-Referer": "http://localhost",
		"X-Title": "super-searcher",
	}
	body = {
		"model": OPENROUTER_MODEL_ID_STEP1,
		"messages": [
			{"role": "system", "content": system_msg},
			{"role": "user", "content": question},
		],
	}

	messages = [
		{"role": "system", "content": system_msg},
		{"role": "user", "content": question},
	]

	response = _api_post_with_retry(url, headers, body)
	response.raise_for_status()
	data = response.json()
	content = (data["choices"][0]["message"].get("content") or "").strip()
	if not content:
		content = (
			"SUPERINTENDENT_FULL_NAME: UNKNOWN\n"
			"FOUND_ON_DISTRICT_WEBSITE: no\n"
			"TITLE_IS_SUPERINTENDENT: no\n"
			"SOURCE_CURRENT_SCHOOL_YEAR: no\n"
			"MULTIPLE_SOURCES_AGREE: no\n"
			"CONFLICTING_INFO_FOUND: no\n"
			"STRUCTURAL_UNCERTAINTY: no\n"
			"SUPERINTENDENT_TRANSITION: no\n"
			"DISTRICT_WEBSITE_ACCESSIBLE: no\n"
			"DISTRICT_MAILING_ADDRESS: \n"
			"EVIDENCE_SUMMARY: Model returned empty response; no search was performed.\n"
			"UNKNOWN_REASON: Model returned empty response; no search results available.\n"
			"SOURCE_URL_1: \nSOURCE_TYPE_1: none\nSOURCE_DATE_1: \n"
			"SOURCE_URL_2: \nSOURCE_TYPE_2: none\nSOURCE_DATE_2: \n"
		)
	messages.append({"role": "assistant", "content": content})
	print("First model (OpenRouter) answer:\n")
	print(content)
	print("\n--- End of first answer ---\n")
	return content, messages


def ask_superintendent_retry_with_openrouter(
	prior_messages: list[dict],
	lea_name: str, state_name: str, city: str = "",
	lea_id: str = "", website: str = "",
	prior_unknown_reason: str = "", prior_evidence_summary: str = "",
	state_abbr: str = "", lea_type_text: str = "",
) -> str:
	"""Retry step 1 as a multi-turn follow-up continuing the prior conversation.

	Appends a follow-up user message to the existing conversation history
	(system + user + assistant from step 1) so the model has full context
	from the first attempt and can refine its search.
	"""
	api_key = get_api_key()

	state_search = state_name
	if state_abbr:
		state_search = f"{state_name} ({state_abbr})"

	website_hint = f" District website: {website}." if website else ""

	context = ""
	if prior_unknown_reason:
		context = f"Your previous search didn't find the superintendent: {prior_unknown_reason}. "
	elif prior_evidence_summary:
		context = f"Your previous answer had weak evidence: {prior_evidence_summary}. "

	state_source_hint = ""
	if state_abbr:
		sa = state_abbr.upper()
		if sa == "VT":
			state_source_hint = " Also check https://www.vtvsa.org/superintendents/ which lists all current VT superintendents."
		elif sa == "FL":
			state_source_hint = " Also check https://www.fldoe.org/accountability/data-sys/school-dis-data/superintendents.stml which lists all current FL superintendents."
		elif sa == "CA":
			state_source_hint = " Also check the California Department of Education school directory at https://www.cde.ca.gov/schooldirectory/ for superintendent information."
		elif sa == "MT":
			state_source_hint = (
				" Also check the Montana Office of Public Instruction directory at "
				"https://gems.opi.mt.gov/Pages/SearchSchools.aspx for district leadership. "
				"IMPORTANT for small Montana elementary districts: In Montana, very small "
				"elementary districts (especially those with few students or only one school) "
				"often do NOT have their own superintendent. Instead, the elected County "
				"Superintendent of Schools serves as their superintendent. Check the county "
				"government website (e.g., <county>mt.gov/superintendent-of-schools) to find "
				"the county superintendent who oversees this district."
			)
		elif sa == "WI":
			state_source_hint = " Also check the Wisconsin DPI school directory at https://dpi.wi.gov/sms/school-directory for district administrator (superintendent) information."
		elif sa == "AR":
			state_source_hint = " Also check the Arkansas Division of Elementary and Secondary Education directory at https://adedata.arkansas.gov/statewide/Districts/DistrictList.aspx for superintendent information."
		elif sa == "ME":
			state_source_hint = " Also check the Maine DOE school directory at https://www.maine.gov/doe/schools/schoolsearch for superintendent information. Maine districts often belong to school unions (SU), RSUs, or reorganized units (AOS/MDIRSS) — the superintendent may be listed under the parent organization."
		elif sa == "OH":
			state_source_hint = " Also check the Ohio Department of Education and Workforce organization search at https://oeds.ode.state.oh.us/ for district superintendent information."
		elif sa == "NJ":
			state_source_hint = " Also check NJ Department of Education School Performance Reports at https://www.nj.gov/education/sprreports/ which list superintendents by district."
		elif sa == "TX":
			state_source_hint = " Also check the Texas Tribune school directory at https://schools.texastribune.org/districts/ which lists current superintendents for all Texas districts."
		elif sa == "NY":
			state_source_hint = " Also check the NY State Tax Department school superintendent directory at https://www.tax.ny.gov/pdf/publications/orpts/sdiv/school-directory.pdf which lists all current NY superintendents."
		elif sa == "IL":
			state_source_hint = " Also check the Illinois Report Card at https://www.illinoisreportcard.com/ which lists current superintendents for all Illinois districts."
		elif sa == "PA":
			state_source_hint = " Also check the PA EDNA database at http://www.edna.pa.gov/ which lists current superintendents with commission dates."
		elif sa == "MI":
			state_source_hint = " Also check Michigan's Educational Entity Master (EEM) at https://www.michigan.gov/cepi/pk-12/eem which lists superintendent/lead administrator contact info for every Michigan district."
		elif sa == "IN":
			state_source_hint = " Also check the Indiana DOE downloadable school directory at https://www.in.gov/doe/ (look for the current year School Directory XLSX file) which lists superintendent names for all Indiana districts."
		elif sa == "OK":
			state_source_hint = " Also check the Oklahoma State Department of Education school directory at https://sde.ok.gov/state-school-directory which lists superintendent information for all Oklahoma districts."
		elif sa == "MN":
			state_source_hint = " Also check the Minnesota DOE superintendent directory at https://pub.education.mn.gov/MdeOrgView/districts/superintendentsDistricts which lists all current MN district superintendent names, emails, and phone numbers."
		elif sa == "IA":
			state_source_hint = " Also check the Iowa Department of Education public school district directory at https://educate.iowa.gov/ for superintendent information."
		elif sa == "KS":
			state_source_hint = " Also check the Kansas State Department of Education directories at https://www.ksde.gov/Home/Quick-Links/Directories which include a superintendent listing (Kansas Educational Directory PDF) for all USD districts."
		elif sa == "SD":
			state_source_hint = " Also check the South Dakota Department of Education school directory at https://doe.sd.gov/ for superintendent information."
		elif sa == "ND":
			state_source_hint = " Also check North Dakota's Insights education directory at https://insights.nd.gov/Education/MapSearch which lists superintendent names for all ND districts."
		elif sa == "MS":
			state_source_hint = " Also check the Mississippi Association of School Superintendents directory at https://www.superintendents.ms/directory/ which lists superintendent names and contact info for all MS districts."
		elif sa == "KY":
			state_source_hint = " Also check the Kentucky Association of School Superintendents directory at https://www.kysupts.org/kass-members which lists all 171 KY district superintendent names and contact info."
		elif sa == "TN":
			state_source_hint = " Also check the Tennessee Organization of School Superintendents directory at https://www.tosstn.com/districts-directory for superintendent (Director of Schools) information."
		elif sa == "WA":
			state_source_hint = " Also check the Washington OSPI Education Directory at https://eds.ospi.k12.wa.us/ for superintendent information."

	today_iso = date.today().isoformat()
	followup = (
		f"Today is {today_iso}. {context}Search again with these strategies: "
		f"(1) '{lea_name} superintendent {state_name}'; "
		f"(2) {state_search} state education dept superintendent directory; "
		f"(3) '{lea_name} Public Schools' or '{lea_name} School District' superintendent.{website_hint}{state_source_hint}\n\n"
		f"If the district website was difficult to read or navigate, try searching for the "
		f"superintendent through the state education department directory, local news articles, "
		f"or school board meeting minutes instead.\n\n"
		f"If the district has a staff or employee directory that spans multiple pages, check "
		f"ALL pages (page 2, page 3, etc.) — the superintendent may not appear on the first page.\n\n"
		f"If you find a name from 2023–24 with no departure news, report it. "
		f"Remember: report the person who served the MAJORITY of the 2025–26 school year. "
		f"If a transition was Aug–Dec 2025, report the new superintendent; if Jan 2026+, report the earlier one. "
		f"The district website always takes precedence over "
		f"state directories. SUPERINTENDENT_FULL_NAME must be exactly one clean full name, or UNKNOWN. "
		f"No nicknames, qualifiers, or 'name or UNKNOWN if...' constructions. "
		f"Respond with the same structured block as before (including all yes/no evidence signal fields)."
	)

	messages = list(prior_messages) + [{"role": "user", "content": followup}]

	url = "https://openrouter.ai/api/v1/chat/completions"
	headers = {
		"Authorization": f"Bearer {api_key}",
		"Content-Type": "application/json",
		"HTTP-Referer": "http://localhost",
		"X-Title": "super-searcher",
	}
	body = {
		"model": OPENROUTER_MODEL_ID_RETRY,
		"messages": messages,
	}

	response = _api_post_with_retry(url, headers, body)
	response.raise_for_status()
	data = response.json()
	content = (data["choices"][0]["message"].get("content") or "").strip()
	if not content:
		content = (
			"SUPERINTENDENT_FULL_NAME: UNKNOWN\n"
			"FOUND_ON_DISTRICT_WEBSITE: no\n"
			"TITLE_IS_SUPERINTENDENT: no\n"
			"SOURCE_CURRENT_SCHOOL_YEAR: no\n"
			"MULTIPLE_SOURCES_AGREE: no\n"
			"CONFLICTING_INFO_FOUND: no\n"
			"STRUCTURAL_UNCERTAINTY: no\n"
			"SUPERINTENDENT_TRANSITION: no\n"
			"DISTRICT_WEBSITE_ACCESSIBLE: no\n"
			"DISTRICT_MAILING_ADDRESS: \n"
			"EVIDENCE_SUMMARY: Retry returned empty response.\n"
			"UNKNOWN_REASON: Retry returned empty response.\n"
			"SOURCE_URL_1: \nSOURCE_TYPE_1: none\nSOURCE_DATE_1: \n"
			"SOURCE_URL_2: \nSOURCE_TYPE_2: none\nSOURCE_DATE_2: \n"
		)
	print("[Retry] Multi-turn retry answer:\n")
	print(content)
	print("\n--- End of retry answer ---\n")
	return content


_STATE_SU_SOURCE_HINTS: dict[str, str] = {
	"VT": "Also check https://www.vtvsa.org/superintendents/ which lists all current VT superintendents by supervisory union.",
}


def ask_su_superintendent(
	lea_name: str, state_name: str, state_abbr: str = "",
	city: str = "", lea_id: str = "", principal_name: str = "",
) -> tuple[str, str, str]:
	"""Look up the supervisory union that oversees a component district and its superintendent.

	Returns (su_name, su_superintendent, certainty).
	"""
	api_key = get_api_key()

	district_desc = f"{lea_name}, {state_name}"
	if city and city.upper() not in lea_name.upper():
		district_desc += f" (city: {city})"
	if lea_id:
		district_desc += f" [NCES LEAID {lea_id}]"

	source_hint = _STATE_SU_SOURCE_HINTS.get(state_abbr.upper(), "") if state_abbr else ""
	if source_hint:
		source_hint = f" {source_hint}"

	leader_context = ""
	if principal_name:
		leader_context = (
			f" The district's identified leader is {principal_name}. "
			f"Verify whether this person serves as the SU superintendent or if a different person holds that role."
		)

	question = (
		f"{district_desc} is a component district of a supervisory union in {state_name}. "
		f"What is the name of the supervisory union that oversees this district, "
		f"and who is the superintendent of that supervisory union for 2025–2026? "
		f"Search {state_name} state education department records and the supervisory union's website. "
		f"Do not use Wikipedia.{source_hint}{leader_context}"
	)

	system_msg = (
		"You are a researcher identifying US supervisory union superintendents.\n\n"
		"Rules:\n"
		"- Identify the supervisory union (SU) that oversees this component district.\n"
		"- Find the superintendent of that SU who served the MAJORITY of 2025–2026 (Aug 2025 – Jun 2026). "
		"If a transition was Aug–Dec 2025, report the new superintendent; if Jan 2026+, report the earlier one.\n"
		"- The SU's official website always takes precedence over state directories and news. No Wikipedia.\n"
		"- If named superintendent in 2023–24 with no departure news, report that name.\n"
		"- Only use UNKNOWN when the full weight of evidence suggests there is no superintendent — it should be rare.\n"
		"- For SUPERINTENDENT_FULL_NAME: provide exactly one clean full legal name. "
		"Always use the person's full legal name, not a nickname or shortened form "
		"(e.g. 'Timothy' not 'Tim', 'Robert' not 'Bob'). Do not include quotation marks, "
		"parentheses, or special characters other than hyphens and periods. "
		"No quoted nicknames, qualifiers, or conditional language. Never combine a name with UNKNOWN.\n"
		"End with this block:\n"
		"SUPERVISORY_UNION_NAME: <name or UNKNOWN>\n"
		"SUPERINTENDENT_FULL_NAME: <full name or UNKNOWN>\n"
		"FOUND_ON_DISTRICT_WEBSITE: <yes|no>\n"
		"TITLE_IS_SUPERINTENDENT: <yes|no>\n"
		"SOURCE_CURRENT_SCHOOL_YEAR: <yes|no>\n"
		"MULTIPLE_SOURCES_AGREE: <yes|no>\n"
		"CONFLICTING_INFO_FOUND: <yes|no>\n"
		"STRUCTURAL_UNCERTAINTY: <yes|no>\n"
		"SUPERINTENDENT_TRANSITION: <yes|no>\n"
		"DISTRICT_WEBSITE_ACCESSIBLE: <yes|no>\n"
		"SOURCE_URL_1: <url or blank>"
	)

	url = "https://openrouter.ai/api/v1/chat/completions"
	headers = {
		"Authorization": f"Bearer {api_key}",
		"Content-Type": "application/json",
		"HTTP-Referer": "http://localhost",
		"X-Title": "super-searcher",
	}
	body = {
		"model": OPENROUTER_MODEL_ID_STEP1,
		"messages": [
			{"role": "system", "content": system_msg},
			{"role": "user", "content": question},
		],
	}

	response = _api_post_with_retry(url, headers, body)
	response.raise_for_status()
	data = response.json()
	content = (data["choices"][0]["message"].get("content") or "").strip()

	su_name = "UNKNOWN"
	su_super = "UNKNOWN"
	su_signals = EvidenceSignals()

	_SIGNAL_PREFIXES: dict[str, str] = {
		"FOUND_ON_DISTRICT_WEBSITE:": "found_on_district_website",
		"TITLE_IS_SUPERINTENDENT:": "title_is_superintendent",
		"SOURCE_CURRENT_SCHOOL_YEAR:": "source_current_school_year",
		"MULTIPLE_SOURCES_AGREE:": "multiple_sources_agree",
		"CONFLICTING_INFO_FOUND:": "conflicting_info_found",
		"STRUCTURAL_UNCERTAINTY:": "structural_uncertainty",
		"SUPERINTENDENT_TRANSITION:": "superintendent_transition",
		"DISTRICT_WEBSITE_ACCESSIBLE:": "district_website_accessible",
	}

	for line in content.splitlines():
		line_clean = re.sub(r"[*`#]+", "", line).strip()
		if not line_clean:
			continue
		upper = line_clean.upper()
		if upper.startswith("SUPERVISORY_UNION_NAME:"):
			val = line_clean.split(":", 1)[1].strip()
			if val and val.upper() != "UNKNOWN":
				su_name = val
		elif upper.startswith("SUPERINTENDENT_FULL_NAME:"):
			val = line_clean.split(":", 1)[1].strip()
			if val and val.upper() != "UNKNOWN":
				su_super = val
		else:
			for prefix, attr in _SIGNAL_PREFIXES.items():
				if upper.startswith(prefix):
					setattr(su_signals, attr, line_clean.split(":", 1)[1].strip().lower().startswith("yes"))
					break

	# Clean the SU superintendent name (strip citations, parentheticals).
	su_super, _ = _clean_superintendent_name(su_super)

	# Compute confidence from evidence signals.
	su_parsed = ParsedBlock(name=su_super, evidence=su_signals)
	confidence = compute_confidence(su_parsed)

	print(f"  SU lookup: {su_name} → superintendent: {su_super} (confidence: {confidence})")
	return (su_name, su_super, confidence)


def _verify_vt_su_via_vtvsa(
	su_name: str, su_super: str, district_leader: str,
) -> tuple[str, str]:
	"""Verify a VT SU superintendent against the VTVSA directory when names disagree.

	Makes a targeted API call asking specifically about the VTVSA listing
	for the given supervisory union. Returns (verified_name, certainty).
	"""
	api_key = get_api_key()

	question = (
		f"According to https://www.vtvsa.org/superintendents/, who is the current "
		f"superintendent of {su_name} in Vermont? "
		f"This page lists all current Vermont superintendents by supervisory union. "
		f"One candidate is {su_super}. Another candidate is {district_leader}. "
		f"Which name appears on the VTVSA page as superintendent for this supervisory union? "
		f"Check the VTVSA page directly."
	)

	system_msg = (
		"You are verifying a Vermont supervisory union superintendent against the "
		"official VTVSA directory at https://www.vtvsa.org/superintendents/.\n\n"
		"Check that page and report the superintendent listed for the given supervisory union.\n\n"
		"End with this block:\n"
		"SUPERINTENDENT_FULL_NAME: <name from VTVSA or UNKNOWN>\n"
		"FOUND_ON_VTVSA: <yes|no>"
	)

	url = "https://openrouter.ai/api/v1/chat/completions"
	headers = {
		"Authorization": f"Bearer {api_key}",
		"Content-Type": "application/json",
		"HTTP-Referer": "http://localhost",
		"X-Title": "super-searcher",
	}
	body = {
		"model": OPENROUTER_MODEL_ID_STEP1,
		"messages": [
			{"role": "system", "content": system_msg},
			{"role": "user", "content": question},
		],
	}

	response = _api_post_with_retry(url, headers, body)
	response.raise_for_status()
	data = response.json()
	content = (data["choices"][0]["message"].get("content") or "").strip()

	verified_name = "UNKNOWN"
	found_on_vtvsa = False

	for line in content.splitlines():
		line_clean = re.sub(r"[*`#]+", "", line).strip()
		if not line_clean:
			continue
		upper = line_clean.upper()
		if upper.startswith("SUPERINTENDENT_FULL_NAME:"):
			val = line_clean.split(":", 1)[1].strip()
			if val and val.upper() != "UNKNOWN":
				verified_name = val
		elif upper.startswith("FOUND_ON_VTVSA:"):
			found_on_vtvsa = line_clean.split(":", 1)[1].strip().lower().startswith("yes")

	verified_name, _ = _clean_superintendent_name(verified_name)

	if verified_name.upper() == "UNKNOWN":
		verified_confidence = "low"
	elif found_on_vtvsa:
		verified_confidence = "high"
	else:
		verified_confidence = "medium"

	print(f"  VTVSA verification: {verified_name} (confidence: {verified_confidence})")
	return (verified_name, verified_confidence)


def _normalize_su_name(su_name: str) -> str:
	"""Normalize a supervisory union name for cache key comparison.

	Strips bracketed citations ([1], [4]), trailing parentheticals
	((SVSU), (SU035)), and extra whitespace so that variant forms
	from different LLM responses resolve to the same cache key.
	"""
	n = re.sub(r"\s*\[\d+\]", "", su_name).strip()
	n = re.sub(r"\s*\([^)]*\)\s*$", "", n).strip()
	n = re.sub(r"\s+", " ", n)
	return n


def _su_lookup_with_cache(
	su_cache: dict[str, tuple[str, str, str]],
	lea_name: str, state_name: str, **kwargs,
) -> tuple[str, str, str]:
	"""Look up the SU superintendent, checking the cache first.

	On a cache miss, calls ask_su_superintendent and stores the result.
	The cache key is "STATE|SU_NAME" (uppercased and normalized), so all
	component districts of the same SU share one cached result.
	"""
	# Step 1: call the API (we need it to identify the SU name).
	su_name, su_super, su_certainty = ask_su_superintendent(
		lea_name, state_name, **kwargs,
	)

	# Step 2: if we got a valid SU name, check the cache.
	if su_name and su_name.upper() != "UNKNOWN":
		cache_key = f"{state_name.upper()}|{_normalize_su_name(su_name).upper()}"
		if cache_key in su_cache:
			cached = su_cache[cache_key]
			print(f"  SU cache hit: {cached[0]} → {cached[1]} (confidence: {cached[2]})")
			if cached[1] and cached[1].upper() != "UNKNOWN":
				return cached
		# Store this result for future districts in the same SU.
		su_cache[cache_key] = (su_name, su_super, su_certainty)

	return (su_name, su_super, su_certainty)


# Allowed SOURCE_TYPE values from step 1; used for certainty based on source quality.
def _clean_superintendent_name(raw_name: str) -> tuple[str, str]:
	"""Strip citations, parentheticals, nicknames, and qualifier phrases.

	Returns (clean_name, extra_info) where extra_info is everything removed,
	suitable for appending to the justification field.

	The cleaned name will be one full name, two full names separated by a
	comma, or UNKNOWN.  Quoted nicknames (e.g. Andrea "Andre" Davis) are
	removed, and trailing qualifier clauses (e.g. "or UNKNOWN if appointment
	did not take effect") are stripped so only the actual name remains.
	"""
	if not raw_name or raw_name.strip().upper() == "UNKNOWN":
		return (raw_name.strip(), "")

	extras: list[str] = []

	# Split on semicolons — first segment is the primary name, rest is extra.
	parts = raw_name.split(";")
	name = parts[0].strip()
	if len(parts) > 1:
		extras.extend(p.strip() for p in parts[1:] if p.strip())

	# Extract parentheticals like (Acting), (on paid administrative leave).
	parens = re.findall(r"\(([^)]+)\)", name)
	if parens:
		extras.extend(parens)
		name = re.sub(r"\s*\([^)]*\)", "", name).strip()

	# Strip bracketed citation numbers like [1], [2][4].
	name = re.sub(r"\s*\[\d+\]", "", name).strip()

	# Strip quoted nicknames (straight double quotes).
	for nick in re.findall(r'"([^"]+)"', name):
		extras.append(f"nickname: {nick}")
	name = re.sub(r'\s*"[^"]*"\s*', ' ', name)

	# Strip quoted nicknames (curly double quotes).
	for nick in re.findall(r'\u201c([^\u201d]+)\u201d', name):
		extras.append(f"nickname: {nick}")
	name = re.sub(r'\s*\u201c[^\u201d]*\u201d\s*', ' ', name)

	# Strip "or UNKNOWN..." and similar trailing qualifier clauses.
	or_match = re.search(r'\s+or\s+UNKNOWN\b.*', name, flags=re.IGNORECASE)
	if or_match:
		extras.append(or_match.group().strip())
		name = name[:or_match.start()]

	# Strip trailing conditional/qualifier phrases.
	qual_match = re.search(
		r',?\s*\b(?:'
		r'if\s+(?:appointment|confirmed|approved|selected|hired|the\s)|'
		r'pending\s+(?:appointment|confirmation|board|approval)|'
		r'(?:not\s+yet|has\s+not)\s+(?:confirmed|started|taken|begun)|'
		r'subject\s+to\b|awaiting\b|unconfirmed\b|'
		r'to\s+be\s+(?:confirmed|determined|announced)'
		r')\b.*$',
		name, flags=re.IGNORECASE,
	)
	if qual_match:
		extras.append(qual_match.group().strip().lstrip(',').strip())
		name = name[:qual_match.start()]

	# Strip trailing commas and whitespace left over from removals.
	name = name.strip(", ")

	# Collapse multiple whitespace.
	name = re.sub(r'\s{2,}', ' ', name).strip()

	# Strip diacritics (e.g. á→a, ñ→n, ü→u) to ASCII equivalents.
	name = unicodedata.normalize("NFKD", name)
	name = "".join(c for c in name if not unicodedata.combining(c))

	# If cleaning left nothing, return UNKNOWN.
	if not name:
		name = "UNKNOWN"

	extra_info = "; ".join(extras) if extras else ""
	return (name, extra_info)


_DISTRICT_SUFFIXES = [
	"Unified Union School District", "Union School District",
	"Unified School District", "Central School District",
	"City School District", "County School District",
	"County Schools", "Independent School District",
	"Consolidated School District", "Community School District",
	"Community Unit School District", "Regional School District",
	"Area School District", "Public School District",
	"Elementary School District", "Elem School District",
	"High School District", "School District", "School Dist",
	"High School", "Middle School", "Elementary School",
	"Public Schools", "Supervisory Union",
	"R-I", "R-II", "R-III", "R-IV", "R-V", "R-VI",
	"R-VII", "R-VIII", "R-IX", "R-X",
	"SD", "ISD", "CSD", "CUSD", "HSD", "ESD",
]

# CCD abbreviation expansions applied before comparison (order matters:
# longer compound abbreviations must come before shorter ones).
_CCD_ABBREVIATIONS: list[tuple[str, str]] = [
	(r"\bNYC\b", "NEW YORK CITY"),
	(r"\bCUSD\b", "Community Unit School District"),
	(r"\bISD\b", "Independent School District"),
	(r"\bHSD\b", "High School District"),
	(r"\bESD\b", "Elementary School District"),
	(r"\bCSD\b", "Central School District"),
	(r"\bSD\b", "School District"),
	(r"\bH\.?\s+S\.?\b", "High School"),
	(r"\bElem\.?\b", "Elementary"),
	(r"\bSch\.?\b", "School"),
	(r"\bCorp\.?\b", "Corporation"),
	(r"\bTwp\.?\b", "Township"),
	(r"\bFt\.?\b", "Fort"),
	(r"\bMt\.?\b", "Mount"),
	(r"\bSt\.?\b", "Saint"),
	(r"\bJct\.?\b", "Junction"),
	(r"\bPk\.?\b", "Park"),
	(r"\bHts\.?\b", "Heights"),
	(r"\bSprgs\.?\b", "Springs"),
	(r"\bCo\.?\b", "County"),
]


def _normalize_district_name(name: str) -> str:
	"""Normalize a district name for comparison.

	Strips '#', expands common CCD abbreviations (SD → School District, etc.),
	removes 'No.' before numbers, and collapses whitespace.
	"""
	if not name:
		return ""
	n = name.strip()
	n = n.replace("#", "")
	for pattern, replacement in _CCD_ABBREVIATIONS:
		n = re.sub(pattern, replacement, n, flags=re.IGNORECASE)
	n = re.sub(r"\bNo\.?\s+(?=\d)", "", n)
	n = re.sub(r"\s+", " ", n).strip()
	return n


def _extract_district_core(lea_name: str) -> str:
	"""Strip common suffixes to extract the distinctive core of a district name."""
	core = lea_name.strip()
	for suffix in _DISTRICT_SUFFIXES:
		if core.upper().endswith(suffix.upper()):
			core = core[:len(core) - len(suffix)].strip().rstrip("-")
			break
	return core.strip()


_ORG_TYPE_PREFIXES = re.compile(
	r"^(MSAD|RSU|SAD|AOS|MDIRSS|BOCES|RESA|CESA)\b",
	re.IGNORECASE,
)


def _extract_district_type_prefix(name: str) -> str:
	"""Extract an organizational-type prefix (MSAD, RSU, AOS, etc.) if present."""
	m = _ORG_TYPE_PREFIXES.match(name.strip())
	return m.group(1).upper() if m else ""


def _tokenize_district_name(name: str) -> set[str]:
	"""Split a district name into uppercase alphanumeric tokens for overlap comparison."""
	return set(re.findall(r'[A-Za-z0-9]+', name.upper()))


def _extract_domain(url: str) -> str:
	"""Extract the registrable domain from a URL for comparison.

	Returns a lowercased domain without 'www.' prefix, or empty string
	if the URL is empty or unparseable.
	"""
	if not url:
		return ""
	url = url.strip().lower()
	# Strip scheme
	for prefix in ("https://", "http://"):
		if url.startswith(prefix):
			url = url[len(prefix):]
			break
	# Take hostname (before first '/')
	host = url.split("/")[0].split("?")[0].split("#")[0]
	if host.startswith("www."):
		host = host[4:]
	return host


def _source_urls_match_website(source_urls: tuple[str, str], website: str) -> bool:
	"""Check whether at least one source URL shares the same domain as the provided website."""
	if not website:
		return True  # No website to compare against; assume OK
	expected = _extract_domain(website)
	if not expected:
		return True
	for u in source_urls:
		if _extract_domain(u) == expected:
			return True
	return False


def _validate_district_match(
	district_confirmed: str, lea_name: str,
) -> tuple[str, str]:
	"""Compare the model's confirmed district name against the input district.

	Uses organizational-type prefixes, token overlap, and substring matching
	to determine whether two district names refer to the same entity.

	Returns (match_level, reason) where match_level is one of:
	  "match"          – names clearly refer to the same district
	  "soft_mismatch"  – names differ slightly, likely the same district
	  "hard_mismatch"  – names clearly refer to different districts
	"""
	if not district_confirmed or not lea_name:
		return ("match", "")

	lea_norm = _normalize_district_name(lea_name).upper()
	confirmed_norm = _normalize_district_name(district_confirmed).upper()

	if not lea_norm or not confirmed_norm:
		return ("soft_mismatch", "Could not normalize district names for comparison")

	if lea_norm == confirmed_norm:
		return ("match", "")

	# --- Organizational-type prefix check ---
	lea_prefix = _extract_district_type_prefix(lea_norm)
	confirmed_prefix = _extract_district_type_prefix(confirmed_norm)

	# In Maine, MSAD/SAD districts are reorganized into RSU/AOS/MDIRSS —
	# these are equivalent org types and should not trigger hard_mismatch.
	_MAINE_EQUIV_PREFIXES = frozenset({"MSAD", "SAD", "RSU", "AOS", "MDIRSS"})

	if lea_prefix and confirmed_prefix and lea_prefix != confirmed_prefix:
		both_maine_equiv = (lea_prefix in _MAINE_EQUIV_PREFIXES
			and confirmed_prefix in _MAINE_EQUIV_PREFIXES)
		if both_maine_equiv:
			return ("soft_mismatch",
				f"Model confirmed district '{district_confirmed}' (type: {confirmed_prefix}) "
				f"may be a reorganized form of '{lea_name}' (type: {lea_prefix})")
		return ("hard_mismatch",
			f"Model confirmed district '{district_confirmed}' (type: {confirmed_prefix}) "
			f"is a different organization type from input '{lea_name}' (type: {lea_prefix})")

	# --- Full-string substring check (post-normalization) ---
	if lea_norm in confirmed_norm or confirmed_norm in lea_norm:
		return ("match", "")

	# --- Core comparison (strip common suffixes) ---
	input_core = _extract_district_core(_normalize_district_name(lea_name)).upper().strip()
	confirmed_core = _extract_district_core(_normalize_district_name(district_confirmed)).upper().strip()

	if not input_core or not confirmed_core:
		return ("soft_mismatch", "Could not extract distinctive core from district names")

	if input_core == confirmed_core:
		return ("match", "")

	# --- Token overlap on cores ---
	input_tokens = _tokenize_district_name(input_core)
	confirmed_tokens = _tokenize_district_name(confirmed_core)

	if not input_tokens or not confirmed_tokens:
		return ("soft_mismatch", "No tokens to compare after core extraction")

	overlap = input_tokens & confirmed_tokens
	smaller = min(len(input_tokens), len(confirmed_tokens))
	overlap_ratio = len(overlap) / smaller if smaller > 0 else 0

	if overlap_ratio >= 1.0:
		return ("match", "")
	if overlap_ratio >= 0.5 and len(overlap) >= 1:
		return ("soft_mismatch",
			f"Model confirmed district '{district_confirmed}' which partially overlaps "
			f"with input '{lea_name}' (shared tokens: {overlap})")

	return ("hard_mismatch",
		f"Model confirmed district '{district_confirmed}' which does not match "
		f"input '{lea_name}'; result may describe a different district")


_ADDR_ABBREVIATIONS: dict[str, str] = {
	"RD": "ROAD", "ST": "STREET", "AVE": "AVENUE", "BLVD": "BOULEVARD",
	"DR": "DRIVE", "LN": "LANE", "CT": "COURT", "PL": "PLACE",
	"CIR": "CIRCLE", "HWY": "HIGHWAY", "PKY": "PARKWAY", "PKWY": "PARKWAY",
}


def _normalize_address(addr: str) -> str:
	"""Normalize an address string for comparison: uppercase, strip punctuation, expand abbreviations."""
	if not addr:
		return ""
	addr = addr.upper().strip()
	addr = re.sub(r"[.,#\-]+", " ", addr)
	addr = re.sub(r"\s+", " ", addr).strip()
	tokens = addr.split()
	tokens = [_ADDR_ABBREVIATIONS.get(t, t) for t in tokens]
	return " ".join(tokens)


def _extract_zip5(addr: str) -> str:
	"""Extract the 5-digit zip code from an address string, or empty string.

	Prefers the last 5-digit number (zip codes typically appear at the end
	of US addresses), avoiding false matches on PO Box numbers.
	"""
	if not addr:
		return ""
	matches = re.findall(r"\b(\d{5})(?:\-\d{4})?\b", addr)
	return matches[-1] if matches else ""


def _extract_street_number(addr: str) -> str:
	"""Extract the leading street number from an address, or empty string."""
	if not addr:
		return ""
	m = re.match(r"^\s*(\d+)\b", addr.strip())
	return m.group(1) if m else ""


def _validate_address_match(
	nces_address: str, model_address: str,
) -> tuple[str, str]:
	"""Compare the NCES mailing address against the address the model found.

	Zip code is the strongest signal; street number is secondary.

	Returns (match_level, reason) where match_level is one of:
	  "match"          - addresses clearly refer to the same location
	  "soft_mismatch"  - addresses differ slightly, likely the same
	  "hard_mismatch"  - addresses clearly differ (different zip codes)
	  "unknown"        - not enough information to compare
	"""
	if not nces_address or not model_address:
		return ("unknown", "")

	nces_zip = _extract_zip5(nces_address)
	model_zip = _extract_zip5(model_address)

	if nces_zip and model_zip:
		if nces_zip != model_zip:
			return ("hard_mismatch",
				f"NCES zip code {nces_zip} does not match district website zip code {model_zip}; "
				f"likely a different district with a similar name")
		return ("match", "")

	nces_norm = _normalize_address(nces_address)
	model_norm = _normalize_address(model_address)
	if not nces_norm or not model_norm:
		return ("unknown", "")

	nces_tokens = set(nces_norm.split())
	model_tokens = set(model_norm.split())
	overlap = nces_tokens & model_tokens
	smaller = min(len(nces_tokens), len(model_tokens))
	ratio = len(overlap) / smaller if smaller > 0 else 0

	if ratio >= 0.6:
		return ("match", "")
	if ratio >= 0.3:
		return ("soft_mismatch",
			f"NCES address '{nces_address}' partially overlaps with website address '{model_address}'")
	return ("soft_mismatch",
		f"Could not confirm address match between NCES '{nces_address}' and website '{model_address}'")


_PRINCIPAL_TITLES = re.compile(
	r"\b(principal|head\s+of\s+school|headmaster|headmistress|head\s+teacher|business\s+manager|ceo(?:/business\s+manager)?)\b",
	re.IGNORECASE,
)
_SUPERINTENDENT_TITLES = re.compile(
	r"\b(superintendent|supt|district\s+administrator)\b",
	re.IGNORECASE,
)


def _is_principal_not_superintendent(response_text: str, name: str) -> bool:
	"""Detect whether the identified person is a principal rather than a superintendent.

	Scans the response for title keywords near the person's name. Returns True
	if the person is described as a principal/head of school and NOT as a
	superintendent.
	"""
	if not response_text or not name:
		return False
	text = response_text.upper()
	name_upper = name.upper().strip()
	if name_upper == "UNKNOWN":
		return False

	last_name = name.strip().split()[-1].upper() if name.strip() else ""
	if not last_name:
		return False

	# Look for title keywords in a window around the person's name.
	for marker in (name_upper, last_name):
		pos = text.find(marker)
		while pos != -1:
			window_start = max(0, pos - 200)
			window_end = min(len(response_text), pos + len(marker) + 200)
			window = response_text[window_start:window_end]
			has_principal = bool(_PRINCIPAL_TITLES.search(window))
			has_superintendent = bool(_SUPERINTENDENT_TITLES.search(window))
			if has_principal and not has_superintendent:
				return True
			pos = text.find(marker, pos + 1)

	return False


VALID_SOURCE_TYPES = frozenset({"district_website", "government", "news", "other", "none"})
VALID_CONFIDENCE_LEVELS = frozenset({"high", "medium", "low"})
CONFIDENCE_RANK: dict[str, int] = {"low": 1, "medium": 2, "high": 3}


@dataclass
class EvidenceSignals:
	"""Structured yes/no evidence signals from the model's search."""
	found_on_district_website: bool = False
	title_is_superintendent: bool = False
	source_current_school_year: bool = False
	multiple_sources_agree: bool = False
	conflicting_info_found: bool = False
	structural_uncertainty: bool = False
	superintendent_transition: bool = False
	district_website_accessible: bool = False


@dataclass
class ParsedBlock:
	"""All fields parsed from the step-1 structured output block."""
	name: str = "UNKNOWN"
	district_confirmed: str = ""
	district_mailing_address: str = ""
	evidence: EvidenceSignals = None  # type: ignore[assignment]
	evidence_summary: str = ""
	unknown_reason: str = ""
	urls: tuple[str, str] = ("", "")
	types: tuple[str, str] = ("none", "none")
	source_dates: tuple[str, str] = ("", "")

	def __post_init__(self) -> None:
		if self.evidence is None:
			self.evidence = EvidenceSignals()


def parse_structured_superintendent_block(text: str) -> ParsedBlock:
	"""Parse the structured block from step-1 output.

	Extracts: SUPERINTENDENT_FULL_NAME, evidence signals (yes/no fields),
	EVIDENCE_SUMMARY, UNKNOWN_REASON, SOURCE_URL_1..2, SOURCE_TYPE_1..2.

	Uses only the first occurrence of each field so a later value does not overwrite.
	"""
	name = "UNKNOWN"
	district_confirmed = ""
	district_mailing_address = ""
	evidence_summary = ""
	unknown_reason = ""
	urls = ["", ""]
	types = ["none", "none"]
	source_dates = ["", ""]
	signals = EvidenceSignals()
	flags: dict[str, bool] = {}

	def _already(key: str) -> bool:
		if flags.get(key):
			return True
		flags[key] = True
		return False

	def _norm_url(v: str) -> str:
		v = v.strip()
		if not v or v.upper() == "UNKNOWN":
			return ""
		v = re.sub(r"^[<(\[\s]+", "", v)
		v = re.sub(r"[\s>)\]]+$", "", v)
		return v.strip()

	def _norm_type(v: str) -> str:
		parts = (v or "").strip().lower().split()
		t = parts[0] if parts else ""
		return t if t in VALID_SOURCE_TYPES else "none"

	def _parse_yesno(v: str) -> bool:
		return v.strip().lower().startswith("yes")

	# Map of signal field prefixes to EvidenceSignals attribute names.
	_SIGNAL_FIELDS: dict[str, str] = {
		"FOUND_ON_DISTRICT_WEBSITE:": "found_on_district_website",
		"TITLE_IS_SUPERINTENDENT:": "title_is_superintendent",
		"SOURCE_CURRENT_SCHOOL_YEAR:": "source_current_school_year",
		"MULTIPLE_SOURCES_AGREE:": "multiple_sources_agree",
		"CONFLICTING_INFO_FOUND:": "conflicting_info_found",
		"STRUCTURAL_UNCERTAINTY:": "structural_uncertainty",
		"SUPERINTENDENT_TRANSITION:": "superintendent_transition",
		"DISTRICT_WEBSITE_ACCESSIBLE:": "district_website_accessible",
	}

	for line in text.splitlines():
		line = re.sub(r"[*`#]+", "", line).strip()
		if not line:
			continue
		upper = line.upper()
		if upper.startswith("DISTRICT_CONFIRMED:") and not _already("district_confirmed"):
			val = line.split(":", 1)[1].strip()
			if val and val.upper() not in ("UNKNOWN", "N/A", "BLANK", ""):
				district_confirmed = val
		elif upper.startswith("DISTRICT_MAILING_ADDRESS:") and not _already("district_mailing_address"):
			val = line.split(":", 1)[1].strip()
			if val and val.lower() not in ("blank", "n/a", "none", ""):
				district_mailing_address = val
		elif upper.startswith("SUPERINTENDENT_FULL_NAME:") and not _already("name"):
			val = line.split(":", 1)[1].strip()
			if val:
				name = val
		elif upper.startswith("EVIDENCE_SUMMARY:") and not _already("evidence_summary"):
			val = line.split(":", 1)[1].strip()
			if val and val.lower() not in ("blank", "n/a", ""):
				evidence_summary = val
		elif upper.startswith("UNKNOWN_REASON:") and not _already("unknown_reason"):
			val = line.split(":", 1)[1].strip()
			if val and val.lower() not in ("blank", "n/a", "none", ""):
				unknown_reason = val
		elif upper.startswith("SOURCE_URL_1:") and not _already("url1"):
			urls[0] = _norm_url(line.split(":", 1)[1])
		elif upper.startswith("SOURCE_TYPE_1:") and not _already("type1"):
			types[0] = _norm_type(line.split(":", 1)[1])
		elif upper.startswith("SOURCE_URL_2:") and not _already("url2"):
			urls[1] = _norm_url(line.split(":", 1)[1])
		elif upper.startswith("SOURCE_TYPE_2:") and not _already("type2"):
			types[1] = _norm_type(line.split(":", 1)[1])
		elif upper.startswith("SOURCE_DATE_1:") and not _already("date1"):
			val = line.split(":", 1)[1].strip()
			if val and val.lower() not in ("blank", "n/a", "none", ""):
				source_dates[0] = val
		elif upper.startswith("SOURCE_DATE_2:") and not _already("date2"):
			val = line.split(":", 1)[1].strip()
			if val and val.lower() not in ("blank", "n/a", "none", ""):
				source_dates[1] = val
		else:
			for prefix, attr in _SIGNAL_FIELDS.items():
				if upper.startswith(prefix) and not _already(attr):
					val = line.split(":", 1)[1]
					setattr(signals, attr, _parse_yesno(val))
					break

	return ParsedBlock(
		name=name,
		district_confirmed=district_confirmed,
		district_mailing_address=district_mailing_address,
		evidence=signals,
		evidence_summary=evidence_summary,
		unknown_reason=unknown_reason,
		urls=(urls[0], urls[1]),
		types=(types[0], types[1]),
		source_dates=(source_dates[0], source_dates[1]),
	)


def compute_confidence(parsed: ParsedBlock) -> str:
	"""Compute confidence deterministically from evidence signals.

	For named results:
	  +2  found on district website
	  +2  title explicitly includes 'superintendent'
	  +1  source from current school year
	  +1  multiple sources agree
	  -3  conflicting info found (transition dispute, different names)
	  -2  structural uncertainty (unclear governance level)
	  -2  superintendent transition during 2025–26
	  -1  district website not accessible

	For UNKNOWN results (confidence = how thoroughly we searched):
	  +2  district website was accessible (primary source checked)
	  +1  source from current school year
	  +1  multiple sources agree (rare: multiple sources confirm no leader)
	  -2  conflicting info found (suggests someone may exist)
	  -1  structural uncertainty (governance unclear)
	  -1  superintendent transition (suggests someone exists or existed)

	Named thresholds:   >=5 high,  >=3 medium,  else low
	UNKNOWN thresholds:  >=3 high,  >=1 medium,  else low
	"""
	is_unknown = (parsed.name.strip().upper() == "UNKNOWN" or not parsed.name.strip())
	ev = parsed.evidence

	if is_unknown:
		score = 0
		if ev.district_website_accessible:  score += 2
		if ev.source_current_school_year:   score += 1
		if ev.multiple_sources_agree:       score += 1
		if ev.conflicting_info_found:       score -= 2
		if ev.structural_uncertainty:       score -= 1
		if ev.superintendent_transition:    score -= 1

		if score >= 3:
			return "high"
		elif score >= 1:
			return "medium"
		return "low"

	score = 0
	if ev.found_on_district_website:    score += 2
	if ev.title_is_superintendent:      score += 2
	if ev.source_current_school_year:   score += 1
	if ev.multiple_sources_agree:       score += 1
	if ev.conflicting_info_found:       score -= 3
	if ev.structural_uncertainty:       score -= 2
	if ev.superintendent_transition:    score -= 2
	if not ev.district_website_accessible: score -= 1

	if score >= 5:
		return "high"
	elif score >= 3:
		return "medium"
	return "low"


def _build_targeted_followup(evidence: EvidenceSignals, name: str, lea_name: str, website: str = "") -> str:
	"""Build a targeted follow-up prompt based on which evidence signals are weak.

	Returns a specific instruction string addressing the weakest signals,
	or empty string if no targeted followup is useful.
	"""
	hints: list[str] = []

	if not evidence.title_is_superintendent:
		hints.append(
			f"Your previous answer found '{name}' but their title was not 'superintendent.' "
			f"Verify whether there is a superintendent or district administrator above this person. "
			f"Check the district's leadership page, board meeting agendas, or state directory."
		)

	if evidence.conflicting_info_found:
		hints.append(
			"Your previous search found conflicting information about who the superintendent is. "
			"The district's own official website ALWAYS takes precedence over state directories "
			"and news articles. State directories are often months out of date."
		)

	if evidence.superintendent_transition:
		hints.append(
			"Your previous search found evidence of a superintendent transition during 2025–26. "
			"Apply the transition rule: if the transition was Aug–Dec 2025, report the NEW "
			"superintendent (they serve the majority of the year). If Jan 2026 or later, report "
			"the EARLIER superintendent (they served the majority). Note the transition in EVIDENCE_SUMMARY."
		)

	if evidence.structural_uncertainty:
		hints.append(
			"Your previous search was uncertain about the governance structure — whether the "
			"correct leader is at the school level or a higher level (supervisory union, tribal "
			"system, or university). Clarify which organization governs this district and who "
			"serves as its superintendent."
		)

	if not evidence.found_on_district_website and evidence.district_website_accessible and website:
		hints.append(
			f"Your previous search did not find the superintendent on the district's own website ({website}). "
			f"Visit the website directly and check pages like 'About', 'Leadership', 'Staff', "
			f"'Administration', 'Board', or 'Contact' for superintendent information."
		)

	if not evidence.district_website_accessible:
		hints.append(
			"The district website was not accessible in your previous search. Try searching for "
			"the superintendent through the state education department directory, local news, "
			"school board meeting minutes, or social media pages for the district."
		)

	if not hints:
		return ""

	return " ".join(hints)


def ask_superintendent_targeted_retry(
	prior_messages: list[dict],
	evidence: EvidenceSignals, name: str,
	lea_name: str, state_name: str,
	website: str = "", state_abbr: str = "",
) -> str:
	"""Targeted second retry using evidence signals to address specific weaknesses."""
	api_key = get_api_key()

	targeted = _build_targeted_followup(evidence, name, lea_name, website=website)
	if not targeted:
		return ""

	today_iso = date.today().isoformat()
	followup = (
		f"Today is {today_iso}. {targeted}\n\n"
		f"Respond with the same structured block as before (including all yes/no evidence signal fields)."
	)

	messages = list(prior_messages) + [{"role": "user", "content": followup}]

	url = "https://openrouter.ai/api/v1/chat/completions"
	headers = {
		"Authorization": f"Bearer {api_key}",
		"Content-Type": "application/json",
		"HTTP-Referer": "http://localhost",
		"X-Title": "super-searcher",
	}
	body = {
		"model": OPENROUTER_MODEL_ID_RETRY,
		"messages": messages,
	}

	response = _api_post_with_retry(url, headers, body)
	response.raise_for_status()
	data = response.json()
	content = (data["choices"][0]["message"].get("content") or "").strip()
	if not content:
		return ""
	print("[Targeted retry] Answer:\n")
	print(content)
	print("\n--- End of targeted retry answer ---\n")
	return content


_VACANCY_KEYWORDS = re.compile(
	r"\b(retir|resign|depart|vacan|left|stepped\s+down|"
	r"transition|search\s+for|no\s+superintendent|"
	r"position\s+is\s+vacant|superintendent\s+search)\b",
	re.IGNORECASE,
)


def _has_vacancy_signals(unknown_reason: str, evidence_summary: str) -> bool:
	"""Check whether UNKNOWN result mentions a retirement, departure, or vacancy."""
	text = f"{unknown_reason} {evidence_summary}"
	return bool(_VACANCY_KEYWORDS.search(text))


def _ask_superintendent_vacancy_recovery(
	prior_messages: list[dict],
	lea_name: str, state_name: str,
	unknown_reason: str = "", evidence_summary: str = "",
	website: str = "", state_abbr: str = "",
) -> str:
	"""Retry specifically for UNKNOWN results caused by a vacancy/retirement.

	Asks the model to identify who served before the vacancy and apply
	the majority-of-year rule, since someone who served Aug-Jan (6+ months)
	should still be reported.
	"""
	api_key = get_api_key()
	today_iso = date.today().isoformat()

	website_hint = f" District website: {website}." if website else ""

	followup = (
		f"Today is {today_iso}. Your previous search reported UNKNOWN because of a "
		f"superintendent vacancy or retirement. However, per the rules, a current vacancy "
		f"does NOT mean UNKNOWN if someone already served the majority of the 2025-26 school "
		f"year (Aug 2025 – Jun 2026). The school year is 10 months (Aug–Jun). If the previous "
		f"superintendent served from August 2025 through their departure (even if the position "
		f"is now vacant), they likely served the majority.\n\n"
		f"Previous context: {unknown_reason} {evidence_summary}\n\n"
		f"Please identify specifically:\n"
		f"1. Who was the superintendent at the START of the 2025-26 school year (Aug 2025)?\n"
		f"2. When exactly did they depart/retire?\n"
		f"3. Did they serve 5+ months of the 10-month school year?\n\n"
		f"If they served the majority of the year, report their name as "
		f"SUPERINTENDENT_FULL_NAME (not UNKNOWN). The transition rule says: if departure was "
		f"Jan 2026 or later, report the earlier superintendent. If departure was Aug–Dec 2025, "
		f"report the new superintendent (or the earlier one if no replacement was named).{website_hint}\n\n"
		f"Respond with the same structured block as before (including all yes/no evidence signal fields)."
	)

	messages = list(prior_messages) + [{"role": "user", "content": followup}]

	url = "https://openrouter.ai/api/v1/chat/completions"
	headers = {
		"Authorization": f"Bearer {api_key}",
		"Content-Type": "application/json",
		"HTTP-Referer": "http://localhost",
		"X-Title": "super-searcher",
	}
	body = {
		"model": OPENROUTER_MODEL_ID_RETRY,
		"messages": messages,
	}

	response = _api_post_with_retry(url, headers, body)
	response.raise_for_status()
	data = response.json()
	content = (data["choices"][0]["message"].get("content") or "").strip()
	if not content:
		return ""
	print("[Vacancy recovery] Answer:\n")
	print(content)
	print("\n--- End of vacancy recovery answer ---\n")
	return content


def _verify_superintendent_independently(
	name: str, lea_name: str, state_name: str,
	lea_id: str = "", state_abbr: str = "", website: str = "",
	mailing_address: str = "", city: str = "", lea_type_text: str = "",
	operational_schools: str = "",
) -> tuple[str, str, str]:
	"""Independent cross-verification of a superintendent result.

	Makes a completely fresh API call (no prior conversation context) with
	all the same district data the main pipeline receives.  Uses a different
	model family to avoid correlated hallucinations.

	Returns (verified_name, confidence, raw_response) where raw_response is
	the full model output text for downstream adjudication.
	"""
	api_key = get_api_key()
	today_iso = date.today().isoformat()

	# Build district description identical to the main pipeline.
	district = f"{lea_name}, {state_name}"
	district_desc = district
	county_match = re.search(r"\(([^)]+)\)\s*$", lea_name)
	county_hint = ""
	if county_match and not county_match.group(1).strip().isdigit():
		county_hint = f" (county: {county_match.group(1)})"
	if city and city.upper() not in district.upper():
		district_desc += f" (city: {city})"
	if county_hint:
		district_desc += county_hint
	if lea_id:
		district_desc += f" [NCES LEAID {lea_id}]"
	if lea_type_text:
		district_desc += f" (type: {lea_type_text})"
	if operational_schools and operational_schools not in ("", "0"):
		district_desc += f" [{operational_schools} school(s)]"
	if mailing_address:
		district_desc += f" (NCES mailing address: {mailing_address})"

	state_search = state_name
	if state_abbr:
		state_search = f"{state_name} ({state_abbr})"

	website_hint = ""
	if website:
		website_hint = (
			f" The district's official website is {website}. "
			f"Visit this URL directly and check its staff, administration, leadership, "
			f"or about pages for superintendent information before searching elsewhere."
		)

	is_recovery = not name or name.upper() == "UNKNOWN"

	state_convention = (
		"- In many districts (especially small or rural districts in any state), the "
		"superintendent equivalent is titled 'District Administrator' or 'School District "
		"Administrator.' This is especially common in Wisconsin, where 'District Administrator' "
		"is the standard title used in place of 'Superintendent.' If the district has no one "
		"with the title 'superintendent' but does have a 'District Administrator' as the top "
		"district leader, report that person. Search for both 'superintendent' and 'district "
		"administrator' when looking for this district's leader.\n"
	)

	mt_county_rule = ""
	if state_abbr and state_abbr.upper() == "MT":
		mt_county_rule = (
			"- MONTANA COUNTY SUPERINTENDENT: In Montana, very small elementary districts "
			"(especially those with few students or only one school) often do NOT have their "
			"own superintendent. Instead, the elected County Superintendent of Schools serves "
			"as their superintendent. If you cannot find a superintendent on the district's own "
			"website, check the county government website (e.g., <county>mt.gov or "
			"<county>countymt.gov under 'superintendent of schools' or 'education') to find "
			"the county superintendent who oversees this district. Report the county "
			"superintendent if no district-level superintendent exists.\n"
		)

	system_msg = (
		"You are independently verifying a school district superintendent.\n\n"
		+ (
			"A previous search could not identify the superintendent. Your job is to do a "
			"FRESH, independent search to find who the superintendent is.\n\n"
			if is_recovery else
			"A previous search identified a candidate superintendent. Your job is to do a "
			"FRESH, independent search to confirm or correct this finding. Do NOT assume "
			"the candidate is correct — verify from scratch.\n\n"
		)
		+ "Rules:\n"
		"- Find the superintendent for 2025–2026.\n"
		"- In very small or single-school districts, the top leader sometimes holds a combined title such as "
		"'Superintendent/Principal.' If someone has 'superintendent' in their title (even combined), report them.\n"
		"- If the district has NO superintendent or equivalent — i.e. the highest position is principal, "
		"head of school, director, CEO, or business manager with no superintendent title — report UNKNOWN and explain in "
		"UNKNOWN_REASON that the district's highest role is not superintendent.\n"
		"- The district's official website is presumed current and ALWAYS takes precedence over state "
		"directories, news articles, and all other sources. If the district website lists person X as "
		"superintendent but a state directory or news article lists person Y, report person X. "
		"State directories are often months out of date. No Wikipedia.\n"
		"- If the district website has a staff or employee directory, check "
		"ALL pages (page 2, page 3, etc.) — the superintendent may not appear on the first page. "
		"If the directory has a search or filter function, use it to search for 'superintendent' "
		"rather than only browsing pages manually.\n"
		"- If named superintendent in 2023–24 with no departure news, report that name (avg tenure 5–6 yrs).\n"
		"- If the superintendent is on leave, suspended, or removed, report the acting/interim superintendent.\n"
		"- TRANSITION RULE: We want the person who served (or will serve) as superintendent for the "
		"MAJORITY of the 2025–26 school year (Aug 2025 – Jun 2026). If a transition occurred between "
		"August and December 2025, report the NEW superintendent (they will serve the majority of the "
		"year). If a transition occurred in January 2026 or later, report the EARLIER superintendent "
		"(they served the majority of the year). Note any transition details in EVIDENCE_SUMMARY. "
		"If a superintendent served from the start of the school year but then departed, retired, or the "
		"position became vacant partway through, still report that person if they served the majority "
		"(Aug–Jan = 6+ months of the 10-month school year). A current vacancy, ongoing superintendent "
		"search, or retirement does NOT mean UNKNOWN — if someone already served most of the year, "
		"report their name. Example: if a superintendent retired December 31 and no replacement has "
		"been named, report the retired superintendent (they served Aug–Dec, 5 months of the year, "
		"which is the majority if no one else served longer).\n"
		"- Only use UNKNOWN when the full weight of evidence "
		"suggests there is no superintendent or highest-ranking district official — it should be rare.\n"
		"- For SUPERINTENDENT_FULL_NAME: provide exactly one clean full legal name (e.g. 'Jane Smith'). "
		"Always use the person's full legal name, not a nickname or shortened form "
		"(e.g. 'Timothy' not 'Tim', 'Robert' not 'Bob', 'William' not 'Bill'). "
		"Do not include quotation marks, parentheses, or special characters other than "
		"hyphens and periods in the name. "
		"Do NOT include quoted nicknames (e.g. write 'Andrea Davis' not 'Andrea \"Andre\" Davis'), "
		"qualifiers, or conditional language. Never output a name combined with UNKNOWN "
		"(e.g. 'Roberto Euresti or UNKNOWN if appointment did not take effect' is wrong — "
		"just write 'Roberto Euresti'). Report only ONE name — the person who served the majority of the year.\n"
		"- If sources conflict on who the superintendent is, the district's own official website always "
		"takes precedence. If the district website is inaccessible, prefer the most recent evidence.\n"
		"- DISTRICT VERIFICATION: When an NCES mailing address is provided, verify you have the correct "
		"district by checking the address in the footer or contact page of the district website. If the "
		"website's address or zip code does not match the NCES mailing address, you may have found "
		"a different district with a similar name. Report the mailing address you find on the "
		"district website in the DISTRICT_MAILING_ADDRESS field below.\n"
		"- For lab schools and university-affiliated schools, only report someone whose primary role is "
		"leading the K-12 school itself (e.g., 'Head of School', 'School Director', 'Executive Director', "
		"'School Principal'). Any person whose title includes 'Dean' of a university college or department "
		"is university personnel and must be excluded, even if they have administrative authority over the school.\n"
		f"{state_convention}"
		f"{mt_county_rule}"
		"End with this block (answer every field):\n"
		"DISTRICT_CONFIRMED: <exact official district name from your sources, not from the query>\n"
		"SUPERINTENDENT_FULL_NAME: <name or UNKNOWN>\n"
		"FOUND_ON_DISTRICT_WEBSITE: <yes|no> — was this name found on the district's own official website?\n"
		"TITLE_IS_SUPERINTENDENT: <yes|no> — does the source explicitly use the title 'superintendent' or 'district administrator' for this person? Answer 'no' if their title is only principal, director, head of school, CEO, business manager, or similar.\n"
		"SOURCE_CURRENT_SCHOOL_YEAR: <yes|no> — is the primary source clearly from the 2025–26 school year (dated Aug 2025 or later, or an undated district website presumed current)?\n"
		"MULTIPLE_SOURCES_AGREE: <yes|no> — did two or more independent sources name the same person as superintendent?\n"
		"CONFLICTING_INFO_FOUND: <yes|no> — did any source suggest a different person, an ongoing transition, a recent resignation, or any disagreement about who the superintendent is?\n"
		"STRUCTURAL_UNCERTAINTY: <yes|no> — is it unclear whether the correct leader is at the school level or a higher governance level (e.g., supervisory union, tribal school system, university affiliation)?\n"
		"SUPERINTENDENT_TRANSITION: <yes|no> — is there evidence of a superintendent change during the 2025–26 school year (Aug 2025 – Jun 2026), such as one person leaving and another starting?\n"
		"DISTRICT_WEBSITE_ACCESSIBLE: <yes|no> — were you able to access and read the district's website?\n"
		"DISTRICT_MAILING_ADDRESS: <mailing address from district website footer or contact page, or blank if not found>\n"
		"EVIDENCE_SUMMARY: <1–2 sentences explaining what you found and any concerns>\n"
		"UNKNOWN_REASON: <if UNKNOWN, why; else blank>\n"
		"SOURCE_URL_1: <url or blank>\n"
		"SOURCE_TYPE_1: <district_website|government|news|other|none>\n"
		"SOURCE_DATE_1: <YYYY-MM or undated>\n"
		"SOURCE_URL_2: <url or blank>\n"
		"SOURCE_TYPE_2: <district_website|government|news|other|none>\n"
		"SOURCE_DATE_2: <YYYY-MM or undated>"
	)

	if is_recovery:
		question = (
			f"Today is {today_iso}. A previous search could NOT identify the superintendent "
			f"of {district_desc} in {state_search} for the 2025–2026 school year "
			f"(Aug 2025 – Jun 2026). We want the person who served (or will serve) for the majority "
			f"of that school year.\n\n"
			f"IMPORTANT: This district is in {state_search} — do NOT confuse it with any "
			f"same-named district in a different state. Verify that the website and sources you "
			f"find are for the {state_search} district, not a similarly named district elsewhere. "
			f"Do not use Wikipedia.{website_hint}\n\n"
			f"Please do a fresh, independent search to find the current superintendent of this "
			f"district. Search the district website first, then {state_search} state records and news."
		)
	else:
		question = (
			f"Today is {today_iso}. A previous search identified '{name}' as the "
			f"superintendent of {district_desc} in {state_search} for the "
			f"2025–2026 school year (Aug 2025 – Jun 2026). We want the person who served "
			f"(or will serve) for the majority of that school year.\n\n"
			f"IMPORTANT: This district is in {state_search} — do NOT confuse it with any "
			f"same-named district in a different state. Verify that the website and sources you "
			f"find are for the {state_search} district, not a similarly named district elsewhere. "
			f"Do not use Wikipedia.{website_hint}\n\n"
			f"Please independently verify: Is '{name}' actually the current superintendent "
			f"of this district? Search the district website first, then {state_search} state records "
			f"to confirm. If '{name}' is NOT the superintendent, find and report the correct "
			f"person."
		)

	url = "https://openrouter.ai/api/v1/chat/completions"
	headers = {
		"Authorization": f"Bearer {api_key}",
		"Content-Type": "application/json",
		"HTTP-Referer": "http://localhost",
		"X-Title": "super-searcher",
	}
	body = {
		"model": OPENROUTER_MODEL_ID_VERIFY,
		"messages": [
			{"role": "system", "content": system_msg},
			{"role": "user", "content": question},
		],
	}

	response = _api_post_with_retry(url, headers, body, timeout=120)
	response.raise_for_status()
	data = response.json()
	content = (data["choices"][0]["message"].get("content") or "").strip()

	verified_name = "UNKNOWN"
	found_on_website = False
	title_is_supt = False
	current_sy = False
	multi_src = False
	conflicting = False

	for line in content.splitlines():
		line_clean = re.sub(r"[*`#]+", "", line).strip()
		if not line_clean:
			continue
		upper = line_clean.upper()
		if upper.startswith("SUPERINTENDENT_FULL_NAME:"):
			val = line_clean.split(":", 1)[1].strip()
			if val and val.upper() != "UNKNOWN":
				verified_name = val
		elif upper.startswith("FOUND_ON_DISTRICT_WEBSITE:"):
			found_on_website = line_clean.split(":", 1)[1].strip().lower().startswith("yes")
		elif upper.startswith("TITLE_IS_SUPERINTENDENT:"):
			title_is_supt = line_clean.split(":", 1)[1].strip().lower().startswith("yes")
		elif upper.startswith("SOURCE_CURRENT_SCHOOL_YEAR:"):
			current_sy = line_clean.split(":", 1)[1].strip().lower().startswith("yes")
		elif upper.startswith("MULTIPLE_SOURCES_AGREE:"):
			multi_src = line_clean.split(":", 1)[1].strip().lower().startswith("yes")
		elif upper.startswith("CONFLICTING_INFO_FOUND:"):
			conflicting = line_clean.split(":", 1)[1].strip().lower().startswith("yes")

	verified_name, _ = _clean_superintendent_name(verified_name)

	v_score = 0
	if found_on_website:   v_score += 2
	if title_is_supt:      v_score += 2
	if current_sy:         v_score += 1
	if multi_src:          v_score += 1
	if conflicting:        v_score -= 3

	if v_score >= 5:
		v_confidence = "high"
	elif v_score >= 3:
		v_confidence = "medium"
	else:
		v_confidence = "low"

	print(f"  [Verification] verified='{verified_name}', confidence={v_confidence}")
	return (verified_name, v_confidence, content)


def _adjudicate_superintendent(
	pipeline_name: str, pipeline_confidence: str, pipeline_answer: str,
	verification_name: str, verification_confidence: str, verification_answer: str,
	lea_name: str, state_name: str, lea_id: str = "", state_abbr: str = "",
	website: str = "", mailing_address: str = "", city: str = "",
	lea_type_text: str = "", operational_schools: str = "",
) -> tuple[str, str, str, str]:
	"""Final adjudication between pipeline and verification results.

	A third model reviews both full responses and the district data to
	make a final determination — verifying correct district via NCES
	mailing address and determining who served the majority of the
	2025-2026 school year.

	Returns (final_name, final_confidence, adjudication_note, raw_response).
	"""
	api_key = get_api_key()
	today_iso = date.today().isoformat()

	district = f"{lea_name}, {state_name}"
	district_desc = district
	county_match = re.search(r"\(([^)]+)\)\s*$", lea_name)
	county_hint = ""
	if county_match and not county_match.group(1).strip().isdigit():
		county_hint = f" (county: {county_match.group(1)})"
	if city and city.upper() not in district.upper():
		district_desc += f" (city: {city})"
	if county_hint:
		district_desc += county_hint
	if lea_id:
		district_desc += f" [NCES LEAID {lea_id}]"
	if lea_type_text:
		district_desc += f" (type: {lea_type_text})"
	if operational_schools and operational_schools not in ("", "0"):
		district_desc += f" [{operational_schools} school(s)]"
	if mailing_address:
		district_desc += f" (NCES mailing address: {mailing_address})"

	state_search = state_name
	if state_abbr:
		state_search = f"{state_name} ({state_abbr})"

	website_hint = ""
	if website:
		website_hint = f" The district's official website is {website}."

	pipeline_name_display = pipeline_name if pipeline_name and pipeline_name.upper() != "UNKNOWN" else "UNKNOWN"
	verification_name_display = verification_name if verification_name and verification_name.upper() != "UNKNOWN" else "UNKNOWN"

	system_msg = (
		"You are the final adjudicator determining the superintendent of a US school district.\n\n"
		"Two independent searches have been conducted using different AI models. You will review "
		"both complete results and make a final determination. You must:\n\n"
		"1. VERIFY CORRECT DISTRICT: Check that both searches found information about the correct "
		"district. When an NCES mailing address is provided, compare it against the addresses "
		"reported by each search. If a search found a different district with a similar name "
		"(wrong state, wrong city, wrong address), disregard that search's result.\n\n"
		"2. DETERMINE MAJORITY-OF-YEAR SUPERINTENDENT: We want the person who served (or will "
		"serve) as superintendent for the MAJORITY of the 10-month 2025–26 school year "
		"(Aug 2025 – Jun 2026). If a transition occurred between August and December 2025, "
		"report the NEW superintendent (they will serve the majority). If a transition occurred "
		"in January 2026 or later, report the EARLIER superintendent (they served the majority). "
		"A current vacancy, ongoing search, or retirement does NOT mean UNKNOWN — if someone "
		"already served most of the year, report their name.\n\n"
		"3. WEIGH EVIDENCE: Consider the confidence level, source quality, and consistency of "
		"each search. The district's official website ALWAYS takes precedence over state "
		"directories or news. A name found on the district website is stronger evidence than "
		"one found only in a state directory.\n\n"
		"4. RESOLVE CONFLICTS: If the two searches disagree and a district website URL is "
		"provided, you MUST independently visit the district website to verify which name "
		"actually appears on the staff/administration/leadership pages. Do NOT rely on what "
		"either search claims the website says — check it yourself. After visiting the site, "
		"determine which search is more credible based on what you actually found, source "
		"quality, and recency. If both are equally credible, prefer the name found on the "
		"district website. If neither found the name on the district website, prefer the "
		"search with more corroborating sources.\n\n"
		"5. BOARD MEETING MINUTES AS LAST RESORT: If the two searches disagree or there is "
		"significant uncertainty about the superintendent's identity, check the district's "
		"board meeting minutes or agendas. Many districts post monthly board meeting documents "
		"that name the superintendent (e.g. 'Superintendent's Report by [Name]', or the "
		"superintendent listed as presenting or being addressed). Look for the most recent "
		"board minutes or agenda on the district website. This is especially useful for small "
		"districts where the staff page may be outdated or incomplete.\n\n"
		"Rules:\n"
		"- Report exactly one clean full legal name (e.g. 'Jane Smith') or UNKNOWN. "
		"Always use the person's full legal name, not a nickname or shortened form "
		"(e.g. 'Timothy' not 'Tim', 'Robert' not 'Bob'). Do not include quotation marks, "
		"parentheses, or special characters other than hyphens and periods.\n"
		"- The district's official website is presumed current and takes precedence over all other sources.\n"
		"- In some states (especially Wisconsin), the superintendent equivalent is titled "
		"'District Administrator.' Treat 'District Administrator' as equivalent to 'Superintendent.'\n"
		"- If someone has 'superintendent' or 'district administrator' in their title "
		"(even combined like 'Superintendent/Principal'), report them.\n"
		"- If the district's highest role is only principal, director, business manageror similar with no superintendent "
		"or district administrator title, report UNKNOWN.\n"
		"- Only use UNKNOWN when both searches failed to identify a superintendent and you have no "
		"basis to determine one.\n"
		"- Do not use Wikipedia.\n\n"
		"End with this block:\n"
		"FINAL_NAME: <name or UNKNOWN>\n"
		"CHOSEN_SOURCE: <pipeline|verification|both_agree|neither> — which search result did you rely on?\n"
		"DISTRICT_VERIFIED: <yes|no> — did you confirm this is the correct district (address/state match)?\n"
		"CONFIDENCE: <high|medium|low>\n"
		"ADJUDICATION_REASON: <1–3 sentences explaining your decision>"
	)

	question = (
		f"Today is {today_iso}. We need to determine the superintendent of "
		f"{district_desc} in {state_search} for the 2025–2026 school year "
		f"(Aug 2025 – Jun 2026).{website_hint}\n\n"
		f"--- SEARCH 1 (Pipeline) ---\n"
		f"Superintendent found: {pipeline_name_display}\n"
		f"Confidence: {pipeline_confidence}\n"
		f"Full response:\n{pipeline_answer}\n\n"
		f"--- SEARCH 2 (Independent verification) ---\n"
		f"Superintendent found: {verification_name_display}\n"
		f"Confidence: {verification_confidence}\n"
		f"Full response:\n{verification_answer}\n\n"
		f"Based on these two independent searches, who is the superintendent of this district "
		f"for the majority of the 2025–2026 school year? Verify that both searches found the "
		f"correct district (check state, city, and mailing address match). Then make your final "
		f"determination."
	)

	url = "https://openrouter.ai/api/v1/chat/completions"
	headers = {
		"Authorization": f"Bearer {api_key}",
		"Content-Type": "application/json",
		"HTTP-Referer": "http://localhost",
		"X-Title": "super-searcher",
	}
	body = {
		"model": OPENROUTER_MODEL_ID_ADJUDICATE,
		"messages": [
			{"role": "system", "content": system_msg},
			{"role": "user", "content": question},
		],
	}

	response = _api_post_with_retry(url, headers, body, timeout=120)
	response.raise_for_status()
	data = response.json()
	content = (data["choices"][0]["message"].get("content") or "").strip()

	final_name = "UNKNOWN"
	chosen_source = ""
	district_verified = False
	confidence = "low"
	reason = ""

	for line in content.splitlines():
		line_clean = re.sub(r"[*`#]+", "", line).strip()
		if not line_clean:
			continue
		upper = line_clean.upper()
		if upper.startswith("FINAL_NAME:"):
			val = line_clean.split(":", 1)[1].strip()
			if val and val.upper() != "UNKNOWN":
				final_name = val
		elif upper.startswith("CHOSEN_SOURCE:"):
			chosen_source = line_clean.split(":", 1)[1].strip().lower()
		elif upper.startswith("DISTRICT_VERIFIED:"):
			district_verified = line_clean.split(":", 1)[1].strip().lower().startswith("yes")
		elif upper.startswith("CONFIDENCE:"):
			val = line_clean.split(":", 1)[1].strip().lower()
			if val in VALID_CONFIDENCE_LEVELS:
				confidence = val
		elif upper.startswith("ADJUDICATION_REASON:"):
			reason = line_clean.split(":", 1)[1].strip()

	final_name, _ = _clean_superintendent_name(final_name)

	adjudication_note = (
		f"[ADJUDICATION: chose={chosen_source}, district_verified={district_verified}, "
		f"reason={reason}]"
	)

	print(f"  [Adjudication] final='{final_name}', chosen={chosen_source}, "
		  f"district_verified={district_verified}, confidence={confidence}")
	return (final_name, confidence, adjudication_note, content)


def _ask_superintendent_mismatch_retry(
	prior_messages: list[dict],
	wrong_district: str, correct_lea_name: str,
	state_name: str, lea_id: str = "", website: str = "",
) -> str:
	"""Retry after the model researched the wrong district.

	Appends a follow-up message to the existing conversation making clear
	that the model's confirmed district does not match the requested one,
	and asks it to search specifically for the correct district.
	"""
	api_key = get_api_key()
	today_iso = date.today().isoformat()

	website_hint = f" The correct district's website is {website}." if website else ""

	followup = (
		f"Today is {today_iso}. IMPORTANT: Your previous answer was about "
		f"'{wrong_district}', but I asked about '{correct_lea_name}' "
		f"(NCES LEAID {lea_id}) in {state_name}. These are DIFFERENT districts. "
		f"Please search specifically for the superintendent of "
		f"'{correct_lea_name}' in {state_name}.{website_hint}\n\n"
		f"Respond with the same structured block as before "
		f"(including all yes/no evidence signal fields)."
	)

	messages = list(prior_messages) + [{"role": "user", "content": followup}]

	url = "https://openrouter.ai/api/v1/chat/completions"
	headers = {
		"Authorization": f"Bearer {api_key}",
		"Content-Type": "application/json",
		"HTTP-Referer": "http://localhost",
		"X-Title": "super-searcher",
	}
	body = {
		"model": OPENROUTER_MODEL_ID_RETRY,
		"messages": messages,
	}

	response = _api_post_with_retry(url, headers, body)
	response.raise_for_status()
	data = response.json()
	content = (data["choices"][0]["message"].get("content") or "").strip()
	if not content:
		return ""
	print("[Mismatch retry] Answer:\n")
	print(content)
	print("\n--- End of mismatch retry answer ---\n")
	return content


def write_superintendent_csv_with_openrouter(
	first_answer: str, district: str, lea_id: str
) -> tuple[list[str], str, str, str]:
	"""Step 2: Build a single CSV row from identity only.

	If step 1's structured block parsed cleanly (name, URLs, types all present),
	skip the expensive second LLM call and use the parsed data directly.
	Otherwise, fall back to the second model for extraction.

	Returns (row_fields, certainty, evidence_summary, unknown_reason).
	"""

	api_key = get_api_key()
	today_str = date.today().isoformat()
	# Split district like "New Haven, CT" into name and state.
	if "," in district:
		district_name, district_state = [part.strip() for part in district.split(",", 1)]
	else:
		district_name, district_state = district.strip(), ""
	district_name = district_name.replace("#", "").strip()
	district_name = re.sub(r"\s{2,}", " ", district_name)

	# Parse step 1 block.
	parsed = parse_structured_superintendent_block(first_answer)
	certainty = compute_confidence(parsed)

	# Fast path: if the structured block parsed cleanly, skip the step 2 LLM call.
	parsed_has_urls = any(parsed.urls)
	parsed_has_types = any(t != "none" for t in parsed.types)
	is_unknown = (parsed.name.strip().upper() == "UNKNOWN" or not parsed.name.strip())
	step1_clean = (parsed.name and (parsed_has_urls or parsed_has_types or is_unknown))

	if step1_clean:
		print("[Step 2] Skipping second LLM call — step 1 structured block parsed cleanly.")
		ev = parsed.evidence
		print(f"  Evidence signals: district_website={ev.found_on_district_website}, "
			  f"title_supt={ev.title_is_superintendent}, current_sy={ev.source_current_school_year}, "
			  f"multi_src={ev.multiple_sources_agree}, conflict={ev.conflicting_info_found}, "
			  f"structural_unc={ev.structural_uncertainty}, transition={ev.superintendent_transition}, "
			  f"site_accessible={ev.district_website_accessible}")
		print(f"  Computed confidence: {certainty}")
		row_fields = [
			lea_id, today_str, district_name, district_state, parsed.name,
			parsed.urls[0], parsed.source_dates[0],
			parsed.urls[1], parsed.source_dates[1],
		]
		print("Parsed CSV row:")
		print(",".join(row_fields[1:]))
		return (row_fields, certainty, parsed.evidence_summary, parsed.unknown_reason)

	# Slow path: step 1 output was messy; use second model to extract.
	print("[Step 2] Step 1 block incomplete; calling second model for extraction.")
	prompt = (
		f"Extract the 2025–2026 superintendent for {district_name}, {district_state} "
		"from the text below. Respond with exactly one CSV row (no header, no explanation).\n"
		f"Format: {today_str},{district_name},{district_state},<full_name>,<source_url_1>,<source_url_2>\n"
		"Rules: prefer interim/acting over deputy; "
		"use UNKNOWN only if closed or truly not identifiable. "
		"If there was a superintendent transition, report the person who served the MAJORITY "
		"of the school year (Aug–Dec transition → new super; Jan+ transition → earlier super). "
		"The full_name field must be exactly one clean full name (no nicknames, no qualifiers, "
		"no 'or UNKNOWN if...'). No Wikipedia URLs.\n\n"
		+ first_answer
	)

	url = "https://openrouter.ai/api/v1/chat/completions"
	headers = {
		"Authorization": f"Bearer {api_key}",
		"Content-Type": "application/json",
		"HTTP-Referer": "http://localhost",
		"X-Title": "super-searcher",
	}
	body = {
		"model": OPENROUTER_MODEL_ID_STEP2,
		"messages": [
			{"role": "system", "content": "You extract CSV rows based on text."},
			{"role": "user", "content": prompt},
		],
	}

	response = _api_post_with_retry(url, headers, body)
	if response.status_code != 200:
		print("\n[Step 2] OpenRouter returned an error:")
		print("Status:", response.status_code)
		print("Body:", response.text)
		response.raise_for_status()
	data = response.json()
	raw_content = (data["choices"][0]["message"].get("content") or "").strip()
	if not raw_content:
		print("[Step 2] Empty response; using step 1 parsed block.")
		row = [
			lea_id, today_str, district_name, district_state, parsed.name or "UNKNOWN",
			parsed.urls[0], parsed.source_dates[0],
			parsed.urls[1], parsed.source_dates[1],
		]
		return (row, certainty, parsed.evidence_summary, parsed.unknown_reason)

	# Find a line that parses to exactly 6 fields.
	EXPECTED_FIELDS = 6
	base_fields: list[str] = []
	for line in raw_content.splitlines():
		line = line.strip()
		if not line:
			continue
		csv_parsed = next(csv.reader([line]))
		if len(csv_parsed) == EXPECTED_FIELDS:
			base_fields = csv_parsed
			break
	if not base_fields:
		first_line = raw_content.splitlines()[0].strip() if raw_content else ""
		parsed_first = next(csv.reader([first_line]))
		if len(parsed_first) == EXPECTED_FIELDS:
			base_fields = parsed_first
	if not base_fields or len(base_fields) != EXPECTED_FIELDS:
		print("[Step 2] Could not parse a valid 6-field row; using step 1 parsed block.")
		row_fields = [
			lea_id, today_str, district_name, district_state, parsed.name or "UNKNOWN",
			parsed.urls[0], parsed.source_dates[0],
			parsed.urls[1], parsed.source_dates[1],
		]
	else:
		sanitized = [f.strip().replace("\n", " ").replace("\r", " ") for f in base_fields]
		sanitized[0] = today_str
		sanitized[1] = district_name
		sanitized[2] = district_state
		# Step 2 row: [date, district_name, district_state, name, url1, url2]
		# Insert source dates from step 1 after each URL.
		row_fields = [
			lea_id, sanitized[0], sanitized[1], sanitized[2], sanitized[3],
			sanitized[4], parsed.source_dates[0],
			sanitized[5], parsed.source_dates[1],
		]

	# Re-derive certainty based on what step 2 actually extracted,
	# since step 1's certainty may not match step 2's result.
	step2_name = row_fields[4] if len(row_fields) > 4 else "UNKNOWN"
	step1_name = parsed.name.strip().upper()
	step2_name_upper = step2_name.strip().upper()
	if step2_name_upper == "UNKNOWN" or not step2_name.strip():
		certainty = "low"
	elif step1_name == "UNKNOWN" or not step1_name:
		certainty = "low"
		parsed.evidence_summary = "Name extracted by second model from unstructured step-1 text; step 1 did not identify a name."
	elif step1_name != step2_name_upper:
		certainty = "low"
		parsed.evidence_summary = (
			f"Step 1 identified '{parsed.name}' but step 2 extracted '{step2_name}'; "
			"names disagree — using step 2 result with low confidence."
		)
		print(f"  WARNING: Step 1 name '{parsed.name}' != Step 2 name '{step2_name}'; downgrading to low confidence.")

	print("Second model (OpenRouter) CSV row:")
	print(",".join(row_fields[1:]))
	return (row_fields, certainty, parsed.evidence_summary, parsed.unknown_reason)


# def _stratified_sample(
# 	districts: list[dict[str, str]], n: int, seed: int,
# ) -> list[dict[str, str]]:
# 	"""Return a stratified sample of size n from districts.
#
# 	Distributes slots equally across lea_type values first, then within
# 	each lea_type equally across level values. Any remainder slots are
# 	allocated to under-represented (lea_type, level) groups.
# 	"""
# 	random.seed(seed)
#
# 	# Group rows by (lea_type, level).
# 	from collections import defaultdict
# 	by_type: dict[str, dict[str, list[dict[str, str]]]] = defaultdict(lambda: defaultdict(list))
# 	for row in districts:
# 		lt = row.get("LEA_TYPE", "").strip()
# 		lv = row.get("LEVEL", "").strip()
# 		by_type[lt][lv].append(row)
#
# 	lea_types = sorted(by_type.keys())
# 	num_types = len(lea_types)
# 	base_per_type = n // num_types
# 	extra_type_slots = n % num_types
#
# 	# Distribute extra type-level slots to the largest lea_types first.
# 	type_sizes = sorted(lea_types, key=lambda t: sum(len(v) for v in by_type[t].values()), reverse=True)
# 	type_budgets: dict[str, int] = {}
# 	for i, lt in enumerate(type_sizes):
# 		type_budgets[lt] = base_per_type + (1 if i < extra_type_slots else 0)
#
# 	sampled: list[dict[str, str]] = []
# 	for lt in lea_types:
# 		budget = type_budgets[lt]
# 		levels = sorted(by_type[lt].keys())
# 		num_levels = len(levels)
# 		base_per_level = budget // num_levels
# 		extra_level_slots = budget % num_levels
#
# 		# Give extra level slots to the largest level groups first.
# 		level_sizes = sorted(levels, key=lambda lv: len(by_type[lt][lv]), reverse=True)
# 		level_budgets: dict[str, int] = {}
# 		for i, lv in enumerate(level_sizes):
# 			level_budgets[lv] = base_per_level + (1 if i < extra_level_slots else 0)
#
# 		for lv in levels:
# 			pool = by_type[lt][lv]
# 			take = min(level_budgets[lv], len(pool))
# 			sampled.extend(random.sample(pool, take))
#
# 	# If any slots remain (because some groups were smaller than their budget),
# 	# fill from the unselected rows.
# 	if len(sampled) < n:
# 		selected_ids = {id(r) for r in sampled}
# 		remaining = [r for r in districts if id(r) not in selected_ids]
# 		random.shuffle(remaining)
# 		sampled.extend(remaining[: n - len(sampled)])
#
# 	random.shuffle(sampled)
#
# 	# Print distribution summary.
# 	from collections import Counter
# 	type_counts = Counter(r.get("LEA_TYPE", "").strip() for r in sampled)
# 	level_counts = Counter(r.get("LEVEL", "").strip() for r in sampled)
# 	print(f"Stratified sample: {len(sampled)} districts")
# 	print(f"  By LEA_TYPE: {dict(sorted(type_counts.items()))}")
# 	print(f"  By LEVEL:    {dict(sorted(level_counts.items()))}")
# 	return sampled


def main() -> None:
	"""Run the pipeline for all open districts from ccd_processed.csv."""

	start_time = datetime.now()
	print(f"Run started at: {start_time.isoformat(timespec='seconds')}")

	# Step 0: use existing ccd_processed.csv if present; otherwise regenerate.
	processed_path = os.path.join(os.getcwd(), "ccd_processed.csv")
	if os.path.exists(processed_path):
		print(f"Using existing {processed_path}; skipping preprocessing.")
	else:
		preprocess_ccd_districts()

	# preprocess_ccd_districts()  # (old: always regenerate)

	results_filename = f"superintendents-{date.today().isoformat()}.csv"
	csv_header = [
		"LEAID",
		"district_name",
		"district_state",
		"superintendent",
		"source_url_1",
		"source_url_2",
		"certainty",
		"found_on_district_website",
		"title_is_superintendent",
		"source_current_school_year",
		"multiple_sources_agree",
		"conflicting_info_found",
		"structural_uncertainty",
		"superintendent_transition",
		"district_website_accessible",
		"justification_main",
		"justification_verification",
		"justification_judge",
	]

	# Resumability: if the output file already exists, read processed LEAIDs
	# so we can skip them and append new results instead of starting over.
	already_processed: set[str] = set()
	resume_mode = os.path.exists(results_filename)
	if resume_mode:
		with open(results_filename, "r", newline="", encoding="utf-8") as existing:
			reader = csv.DictReader(existing)
			for row in reader:
				lid = row.get("LEAID", "").strip()
				if lid:
					already_processed.add(lid)
		print(f"Resuming: {len(already_processed)} LEAIDs already processed in {results_filename}")

	# Audit log: raw step-1 responses keyed by LEAID for debugging.
	log_filename = f"search-log-{date.today().isoformat()}.txt"
	log_open_mode = "a" if resume_mode else "w"

	open_mode = "a" if resume_mode else "w"
	with open(results_filename, open_mode, newline="", encoding="utf-8") as outfile, \
		 open(log_filename, log_open_mode, encoding="utf-8") as logfile:
		writer = csv.writer(outfile)
		if not resume_mode:
			writer.writerow(csv_header)

		ccd_path = os.path.join(os.getcwd(), "ccd_processed.csv")
		if not os.path.exists(ccd_path):
			print("Warning: ccd_processed.csv not found; skipping district loop.")
			return

		with open(ccd_path, "r", newline="", encoding="utf-8") as ccdfile:
			reader = csv.DictReader(ccdfile)
			all_eligible = [
				row for row in reader
				if row.get("SY_STATUS_TEXT") == "Open"
				and row.get("LEA_TYPE", "").strip() in ("1", "2")
				and row.get("LEVEL", "") not in ("Adult Education", "Not applicable", "Not reported")
				and row.get("STATENAME", "").upper() != "BUREAU OF INDIAN EDUCATION"
				and (row.get("OPERATIONAL_SCHOOLS", "").strip() == "" or int(row.get("OPERATIONAL_SCHOOLS", "0")) >= 1)
			]

			open_districts = list(all_eligible)

			if ALLOWED_LEAIDS:
				open_districts = [row for row in open_districts if row.get("LEAID", "").strip() in ALLOWED_LEAIDS]
			elif RUN_MODE == "sample" and len(open_districts) > SAMPLE_SIZE:
				random.seed(RANDOM_SEED)
				open_districts = random.sample(open_districts, SAMPLE_SIZE)

			# Cache SU superintendent results by "STATE|SU_NAME" to avoid
			# redundant API calls when multiple districts share the same SU.
			su_cache: dict[str, tuple[str, str, str]] = {}
			# NYC Chancellor name, looked up once on first NY LEA_TYPE=2 district.
			nyc_chancellor: Optional[str] = None

			total = len(open_districts)
			for idx, row in enumerate(open_districts, 1):
				lea_name = row.get("LEA_NAME", "").strip()
				state_name = row.get("STATENAME", "").strip()
				state_abbr = row.get("ST", "").strip()
				lea_id = row.get("LEAID", "").strip()
				city = row.get("MCITY", "").strip()
				lea_type = row.get("LEA_TYPE", "").strip()
				lea_type_text = row.get("LEA_TYPE_TEXT", "").strip()
				level = row.get("LEVEL", "").strip()
				website = row.get("WEBSITE", "").strip()
				operational_schools = row.get("OPERATIONAL_SCHOOLS", "").strip()
				mstreet1 = row.get("MSTREET1", "").strip()
				mzip = row.get("MZIP", "").strip()
				mailing_address = ""
				if mstreet1 and city:
					mailing_address = f"{mstreet1}, {city}, {state_abbr} {mzip}".strip()
				if not lea_name or not state_name:
					continue
				if lea_id in already_processed:
					continue

				district = f"{lea_name}, {state_name}"
				print(f"\n{'='*60}")
				print(f"[{idx}/{total}] Processing: {district} (LEAID={lea_id}, LEA_TYPE={lea_type}, LEVEL={level})")
				print(f"{'='*60}")
				try:
					first_answer, step1_messages = ask_superintendent_with_openrouter(
						district, state_name, lea_id=lea_id, city=city,
						lea_type_text=lea_type_text, state_abbr=state_abbr, website=website,
						operational_schools=operational_schools,
						mailing_address=mailing_address,
					)
					logfile.write(f"{'='*60}\nLEAID={lea_id} | {district} | Step 1\n{'='*60}\n{first_answer}\n\n")
					logfile.flush()
					row_fields, certainty, evidence_summary, unknown_reason = write_superintendent_csv_with_openrouter(
						first_answer, district, lea_id
					)
					final_answer = first_answer
					is_unknown = len(row_fields) > 4 and (row_fields[4] or "").strip().upper() == "UNKNOWN"
					needs_retry = is_unknown or certainty in ("low", "medium")

					# Check step-1 sources for issues that warrant a retry.
					parsed_for_checks = parse_structured_superintendent_block(first_answer)

					# Detect Wikipedia sources (prohibited) and force retry.
					has_wikipedia = any("wikipedia.org" in (u or "").lower() for u in parsed_for_checks.urls)
					if has_wikipedia:
						print(f"  Wikipedia source detected; forcing retry.")
						website_directive = (
							f" Visit the district's official website at {website} directly and check "
							f"its staff, administration, leadership, or about pages."
						) if website else ""
						wiki_note = (
							f"Previous search used Wikipedia, which is not an allowed source. "
							f"Search again without Wikipedia.{website_directive} "
							f"Also check {state_name} state education department superintendent "
							f"directory and recent local news."
						)
						if is_unknown:
							unknown_reason = f"{unknown_reason} {wiki_note}" if unknown_reason else wiki_note
						else:
							evidence_summary = wiki_note
						needs_retry = True

					# Detect stale sources (all sources pre-2024) and force
					# retry with stronger search guidance.
					if not has_wikipedia and not is_unknown:
						source_dates_raw = [
							parsed_for_checks.source_dates[0],
							parsed_for_checks.source_dates[1],
						]
						all_stale = True
						has_any_date = False
						for sd in source_dates_raw:
							if not sd or sd.lower() in ("undated", ""):
								continue
							has_any_date = True
							year_match = re.search(r"20(\d{2})", sd)
							if year_match and int(year_match.group(0)) >= 2024:
								all_stale = False
								break
						if has_any_date and all_stale:
							print(f"  All sources are pre-2024; forcing retry for fresher evidence.")
							stale_note = (
								f"All sources in your previous answer are from before 2024 and may be "
								f"outdated. The superintendent may have changed since then. Search for "
								f"the CURRENT superintendent for the 2025-2026 school year using recent "
								f"sources."
							)
							if website:
								stale_note += (
									f" Visit the district's official website at {website} directly."
								)
							evidence_summary = stale_note
							needs_retry = True

					# When UNKNOWN but source URLs were found, include them in retry context.
					if is_unknown:
						found_urls = [u for u in parsed_for_checks.urls if u]
						if found_urls:
							url_note = (
								f"Your previous search found these pages but could not extract a superintendent name: "
								f"{', '.join(found_urls)}. Check them again carefully and extract the name."
							)
							unknown_reason = f"{unknown_reason} {url_note}" if unknown_reason else url_note

					if needs_retry:
						reason = "UNKNOWN result" if is_unknown else f"low confidence ({certainty})"
						print(f"Retrying {district} (LEAID={lea_id}): {reason}...")
						try:
							retry_answer = ask_superintendent_retry_with_openrouter(
								step1_messages, lea_name, state_name,
								city=city, lea_id=lea_id, website=website,
								prior_unknown_reason=unknown_reason, prior_evidence_summary=evidence_summary,
								state_abbr=state_abbr, lea_type_text=lea_type_text,
							)
							logfile.write(f"{'='*60}\nLEAID={lea_id} | {district} | Retry\n{'='*60}\n{retry_answer}\n\n")
							logfile.flush()
							retry_fields, retry_certainty, retry_evidence_summary, retry_unknown_reason = write_superintendent_csv_with_openrouter(
								retry_answer, district, lea_id
							)
							retry_is_unknown = (retry_fields[4] or "").strip().upper() == "UNKNOWN" if len(retry_fields) > 4 else True
							retry_improved = (
								(is_unknown and not retry_is_unknown)
								or (not retry_is_unknown and CONFIDENCE_RANK.get(retry_certainty, 0) > CONFIDENCE_RANK.get(certainty, 0))
							)
							if retry_improved:
								row_fields = retry_fields
								certainty = retry_certainty
								final_answer = retry_answer
								if retry_evidence_summary:
									evidence_summary = retry_evidence_summary
								if retry_unknown_reason:
									unknown_reason = retry_unknown_reason
							else:
								print(f"  Retry did not improve result; keeping original.")
						except Exception as retry_err:
							print(f"Retry failed for {district} (LEAID={lea_id}): {retry_err}")

					# Targeted second retry for medium/low results using evidence signals.
					current_name = (row_fields[4] or "").strip()
					if (certainty in ("medium", "low")
						and current_name.upper() != "UNKNOWN" and current_name):
						current_parsed = parse_structured_superintendent_block(final_answer)
						targeted_followup = _build_targeted_followup(
							current_parsed.evidence, current_name, lea_name, website=website,
						)
						if targeted_followup:
							print(f"  Targeted retry for {certainty} confidence...")
							try:
								# Build message history: append the best answer so far.
								targeted_messages = list(step1_messages)
								if final_answer != first_answer:
									targeted_messages.append({"role": "assistant", "content": final_answer})
								targeted_answer = ask_superintendent_targeted_retry(
									targeted_messages,
									current_parsed.evidence, current_name,
									lea_name, state_name,
									website=website, state_abbr=state_abbr,
								)
								if targeted_answer:
									logfile.write(f"{'='*60}\nLEAID={lea_id} | {district} | Targeted Retry\n{'='*60}\n{targeted_answer}\n\n")
									logfile.flush()
									t_fields, t_certainty, t_summary, t_unknown = write_superintendent_csv_with_openrouter(
										targeted_answer, district, lea_id
									)
									t_is_unknown = (t_fields[4] or "").strip().upper() == "UNKNOWN" if len(t_fields) > 4 else True
									t_improved = (
										not t_is_unknown
										and CONFIDENCE_RANK.get(t_certainty, 0) > CONFIDENCE_RANK.get(certainty, 0)
									)
									if t_improved:
										row_fields = t_fields
										certainty = t_certainty
										final_answer = targeted_answer
										if t_summary:
											evidence_summary = t_summary
										if t_unknown:
											unknown_reason = t_unknown
										print(f"  Targeted retry improved to {certainty}.")
									else:
										print(f"  Targeted retry did not improve result; keeping previous.")
							except Exception as t_err:
								print(f"  Targeted retry failed: {t_err}")

					if (row_fields[4] or "").strip().upper() == "UNKNOWN" and not unknown_reason:
						unknown_reason = "No superintendent information found after initial search and retry."

					# Vacancy recovery: if result is still UNKNOWN and
					# evidence mentions a retirement/departure/vacancy, do a
					# targeted retry asking about the predecessor.
					vac_name = (row_fields[4] or "").strip().upper()
					if (vac_name == "UNKNOWN" or not vac_name) and _has_vacancy_signals(unknown_reason, evidence_summary):
						print(f"  Vacancy signals detected; attempting vacancy recovery retry...")
						try:
							vac_messages = list(step1_messages)
							if final_answer != first_answer:
								vac_messages.append({"role": "assistant", "content": final_answer})
							vac_answer = _ask_superintendent_vacancy_recovery(
								vac_messages, lea_name, state_name,
								unknown_reason=unknown_reason,
								evidence_summary=evidence_summary,
								website=website, state_abbr=state_abbr,
							)
							if vac_answer:
								logfile.write(f"{'='*60}\nLEAID={lea_id} | {district} | Vacancy Recovery\n{'='*60}\n{vac_answer}\n\n")
								logfile.flush()
								vac_fields, vac_certainty, vac_summary, vac_unknown = write_superintendent_csv_with_openrouter(
									vac_answer, district, lea_id
								)
								vac_is_unknown = (vac_fields[4] or "").strip().upper() == "UNKNOWN" if len(vac_fields) > 4 else True
								if not vac_is_unknown:
									row_fields = vac_fields
									certainty = vac_certainty
									final_answer = vac_answer
									if vac_summary:
										evidence_summary = vac_summary
									if vac_unknown:
										unknown_reason = vac_unknown
									print(f"  Vacancy recovery succeeded: {row_fields[4]}")
								else:
									print(f"  Vacancy recovery still UNKNOWN; keeping original.")
						except Exception as vac_err:
							print(f"  Vacancy recovery failed: {vac_err}")

					# Validate that the response actually references the correct district.
					match_level = "match"
					sup_name = (row_fields[4] or "").strip().upper()
					if sup_name and sup_name != "UNKNOWN":
						final_parsed = parse_structured_superintendent_block(final_answer)
						match_level, mismatch_reason = _validate_district_match(
							final_parsed.district_confirmed, lea_name,
						)
						if match_level == "hard_mismatch":
							print(f"  District name hard_mismatch: {mismatch_reason}")
							print(f"  Retrying with explicit district correction...")
							try:
								mismatch_messages = list(step1_messages)
								if final_answer != first_answer:
									mismatch_messages.append({"role": "assistant", "content": final_answer})
								mm_answer = _ask_superintendent_mismatch_retry(
									mismatch_messages,
									wrong_district=final_parsed.district_confirmed,
									correct_lea_name=lea_name,
									state_name=state_name,
									lea_id=lea_id,
									website=website,
								)
								if mm_answer:
									logfile.write(f"{'='*60}\nLEAID={lea_id} | {district} | Mismatch Retry\n{'='*60}\n{mm_answer}\n\n")
									logfile.flush()
									mm_fields, mm_certainty, mm_summary, mm_unknown = write_superintendent_csv_with_openrouter(
										mm_answer, district, lea_id
									)
									mm_parsed = parse_structured_superintendent_block(mm_answer)
									mm_match, _ = _validate_district_match(mm_parsed.district_confirmed, lea_name)
									mm_is_unknown = (mm_fields[4] or "").strip().upper() == "UNKNOWN" if len(mm_fields) > 4 else True
									if mm_match != "hard_mismatch" and not mm_is_unknown:
										row_fields = mm_fields
										certainty = mm_certainty
										final_answer = mm_answer
										if mm_summary:
											evidence_summary = mm_summary
										if mm_unknown:
											unknown_reason = mm_unknown
										print(f"  Mismatch retry succeeded: correct district found.")
									else:
										print(f"  Mismatch retry still wrong district; setting to UNKNOWN.")
										row_fields[4] = "UNKNOWN"
										certainty = "low"
										unknown_reason = f"DISTRICT MISMATCH: {mismatch_reason}"
										evidence_summary = ""
								else:
									row_fields[4] = "UNKNOWN"
									certainty = "low"
									unknown_reason = f"DISTRICT MISMATCH: {mismatch_reason}"
									evidence_summary = ""
							except Exception as mm_err:
								print(f"  Mismatch retry failed: {mm_err}")
								row_fields[4] = "UNKNOWN"
								certainty = "low"
								unknown_reason = f"DISTRICT MISMATCH: {mismatch_reason}"
								evidence_summary = ""
						elif match_level == "soft_mismatch":
							print(f"  District name soft_mismatch: {mismatch_reason}")
							# Escalate to mismatch retry if the model's source
							# URLs don't share a domain with the CCD website.
							urls_ok = _source_urls_match_website(final_parsed.urls, website)
							if not urls_ok and website:
								print(f"  Source URLs don't match provided website ({website}); escalating to mismatch retry...")
								try:
									sm_messages = list(step1_messages)
									if final_answer != first_answer:
										sm_messages.append({"role": "assistant", "content": final_answer})
									sm_answer = _ask_superintendent_mismatch_retry(
										sm_messages,
										wrong_district=final_parsed.district_confirmed,
										correct_lea_name=lea_name,
										state_name=state_name,
										lea_id=lea_id,
										website=website,
									)
									if sm_answer:
										logfile.write(f"{'='*60}\nLEAID={lea_id} | {district} | Soft-Mismatch Retry\n{'='*60}\n{sm_answer}\n\n")
										logfile.flush()
										sm_fields, sm_certainty, sm_summary, sm_unknown = write_superintendent_csv_with_openrouter(
											sm_answer, district, lea_id
										)
										sm_is_unknown = (sm_fields[4] or "").strip().upper() == "UNKNOWN" if len(sm_fields) > 4 else True
										if not sm_is_unknown:
											row_fields = sm_fields
											certainty = sm_certainty
											final_answer = sm_answer
											if sm_summary:
												evidence_summary = sm_summary
											if sm_unknown:
												unknown_reason = sm_unknown
											print(f"  Soft-mismatch retry succeeded.")
										else:
											print(f"  Soft-mismatch retry returned UNKNOWN; keeping original.")
											if evidence_summary:
												evidence_summary = f"{evidence_summary}; NOTE: {mismatch_reason}"
											else:
												evidence_summary = f"NOTE: {mismatch_reason}"
									else:
										if evidence_summary:
											evidence_summary = f"{evidence_summary}; NOTE: {mismatch_reason}"
										else:
											evidence_summary = f"NOTE: {mismatch_reason}"
								except Exception as sm_err:
									print(f"  Soft-mismatch retry failed: {sm_err}")
									if evidence_summary:
										evidence_summary = f"{evidence_summary}; NOTE: {mismatch_reason}"
									else:
										evidence_summary = f"NOTE: {mismatch_reason}"
							else:
								if evidence_summary:
									evidence_summary = f"{evidence_summary}; NOTE: {mismatch_reason}"
								else:
									evidence_summary = f"NOTE: {mismatch_reason}"

					# Source URL vs website domain check: catch cases where
					# the model found a same-named district in a different
					# state/location (e.g. Johnson City NY vs TN) even when
					# district name validation passes.
					url_sup = (row_fields[4] or "").strip().upper()
					if (url_sup and url_sup != "UNKNOWN" and website
						and match_level == "match"):
						url_parsed_check = parse_structured_superintendent_block(final_answer)
						urls_match_website = _source_urls_match_website(url_parsed_check.urls, website)
						if not urls_match_website:
							print(f"  Source URLs don't match expected website ({website}); triggering website-specific retry...")
							try:
								url_mm_messages = list(step1_messages)
								if final_answer != first_answer:
									url_mm_messages.append({"role": "assistant", "content": final_answer})
								url_mm_answer = _ask_superintendent_mismatch_retry(
									url_mm_messages,
									wrong_district=url_parsed_check.district_confirmed or lea_name,
									correct_lea_name=lea_name,
									state_name=state_name,
									lea_id=lea_id,
									website=website,
								)
								if url_mm_answer:
									logfile.write(f"{'='*60}\nLEAID={lea_id} | {district} | URL-Mismatch Retry\n{'='*60}\n{url_mm_answer}\n\n")
									logfile.flush()
									url_mm_fields, url_mm_certainty, url_mm_summary, url_mm_unknown = write_superintendent_csv_with_openrouter(
										url_mm_answer, district, lea_id
									)
									url_mm_is_unknown = (url_mm_fields[4] or "").strip().upper() == "UNKNOWN" if len(url_mm_fields) > 4 else True
									if not url_mm_is_unknown:
										url_mm_parsed = parse_structured_superintendent_block(url_mm_answer)
										url_mm_urls_ok = _source_urls_match_website(url_mm_parsed.urls, website)
										if url_mm_urls_ok or CONFIDENCE_RANK.get(url_mm_certainty, 0) > CONFIDENCE_RANK.get(certainty, 0):
											row_fields = url_mm_fields
											certainty = url_mm_certainty
											final_answer = url_mm_answer
											if url_mm_summary:
												evidence_summary = url_mm_summary
											if url_mm_unknown:
												unknown_reason = url_mm_unknown
											print(f"  URL-mismatch retry succeeded.")
										else:
											print(f"  URL-mismatch retry did not improve; keeping original.")
									else:
										print(f"  URL-mismatch retry returned UNKNOWN; keeping original.")
							except Exception as url_mm_err:
								print(f"  URL-mismatch retry failed: {url_mm_err}")

					# Address-based district verification: catch same-name
					# districts that differ by location (e.g. two "Lakota Local" in OH).
					addr_sup = (row_fields[4] or "").strip().upper()
					if (addr_sup and addr_sup != "UNKNOWN" and mailing_address):
						addr_parsed = parse_structured_superintendent_block(final_answer)
						addr_level, addr_reason = _validate_address_match(
							mailing_address, addr_parsed.district_mailing_address,
						)
						if addr_level == "hard_mismatch":
							print(f"  Address mismatch: {addr_reason}")
							print(f"  Retrying with explicit district correction...")
							try:
								addr_mm_messages = list(step1_messages)
								if final_answer != first_answer:
									addr_mm_messages.append({"role": "assistant", "content": final_answer})
								addr_mm_answer = _ask_superintendent_mismatch_retry(
									addr_mm_messages,
									wrong_district=addr_parsed.district_confirmed or lea_name,
									correct_lea_name=lea_name,
									state_name=state_name,
									lea_id=lea_id,
									website=website,
								)
								if addr_mm_answer:
									logfile.write(f"{'='*60}\nLEAID={lea_id} | {district} | Address Mismatch Retry\n{'='*60}\n{addr_mm_answer}\n\n")
									logfile.flush()
									amm_fields, amm_certainty, amm_summary, amm_unknown = write_superintendent_csv_with_openrouter(
										addr_mm_answer, district, lea_id
									)
									amm_is_unknown = (amm_fields[4] or "").strip().upper() == "UNKNOWN" if len(amm_fields) > 4 else True
									if not amm_is_unknown:
										row_fields = amm_fields
										certainty = amm_certainty
										final_answer = addr_mm_answer
										if amm_summary:
											evidence_summary = amm_summary
										if amm_unknown:
											unknown_reason = amm_unknown
										print(f"  Address mismatch retry succeeded.")
									else:
										print(f"  Address mismatch retry returned UNKNOWN; setting to UNKNOWN.")
										row_fields[4] = "UNKNOWN"
										certainty = "low"
										unknown_reason = f"ADDRESS MISMATCH: {addr_reason}"
										evidence_summary = ""
								else:
									row_fields[4] = "UNKNOWN"
									certainty = "low"
									unknown_reason = f"ADDRESS MISMATCH: {addr_reason}"
									evidence_summary = ""
							except Exception as addr_err:
								print(f"  Address mismatch retry failed: {addr_err}")
								row_fields[4] = "UNKNOWN"
								certainty = "low"
								unknown_reason = f"ADDRESS MISMATCH: {addr_reason}"
								evidence_summary = ""

					# For VT LEA_TYPE=2: always look up SU superintendent.
					current_sup = (row_fields[4] or "").strip()
					if lea_type == "2" and state_abbr.upper() == "VT":
						print(f"  VT LEA_TYPE=2: looking up supervisory union superintendent...")
						su_name, su_super, su_certainty = "UNKNOWN", "UNKNOWN", "low"
						try:
							su_name, su_super, su_certainty = _su_lookup_with_cache(
								su_cache, lea_name, state_name, state_abbr=state_abbr,
								city=city, lea_id=lea_id,
								principal_name=current_sup if current_sup.upper() != "UNKNOWN" else "",
							)
							if su_super and su_super.upper() != "UNKNOWN":
								step1_last = current_sup.split()[-1].upper() if current_sup and current_sup.upper() != "UNKNOWN" else ""
								su_last = su_super.split()[-1].upper() if su_super else ""
								if (step1_last and su_last and step1_last != su_last):
									print(f"  VT SU super '{su_super}' differs from step-1 leader '{current_sup}'; verifying via VTVSA...")
									try:
										vtvsa_name, vtvsa_conf = _verify_vt_su_via_vtvsa(
											su_name, su_super, current_sup,
										)
										if vtvsa_name and vtvsa_name.upper() != "UNKNOWN":
											su_super = vtvsa_name
											su_certainty = vtvsa_conf
											print(f"  VTVSA verification chose: {su_super}")
									except Exception as verify_err:
										print(f"  VTVSA verification failed: {verify_err}")
								principal_note = (
									f"district leader is {current_sup} (principal)"
									if current_sup and current_sup.upper() != "UNKNOWN"
									else ""
								)
								row_fields[4] = su_super
								certainty = su_certainty
								su_label = f" ({su_name})" if su_name and su_name.upper() != "UNKNOWN" else ""
								evidence_summary = f"SU superintendent{su_label}"
								if principal_note:
									evidence_summary += f"; {principal_note}"
								print(f"  Replaced with SU superintendent: {su_super}")
							else:
								print(f"  Could not determine SU superintendent; keeping original result.")
						except Exception as su_err:
							print(f"  SU superintendent lookup failed: {su_err}")

					# For other states' LEA_TYPE=2 (except NY): trigger SU
					# lookup only when the result is detected as a principal.
					elif (lea_type == "2"
						and state_abbr.upper() not in ("NY", "VT")
						and current_sup.upper() != "UNKNOWN"
						and current_sup
						and _is_principal_not_superintendent(final_answer, current_sup)):
						print(f"  LEA_TYPE=2: '{current_sup}' appears to be a principal, not a superintendent.")
						print(f"  Looking up supervisory union superintendent...")
						try:
							su_name, su_super, su_certainty = _su_lookup_with_cache(
								su_cache, lea_name, state_name, state_abbr=state_abbr,
								city=city, lea_id=lea_id, principal_name=current_sup,
							)
							if su_super and su_super.upper() != "UNKNOWN":
								row_fields[4] = su_super
								certainty = su_certainty
								su_label = f" ({su_name})" if su_name and su_name.upper() != "UNKNOWN" else ""
								evidence_summary = (
									f"SU superintendent{su_label}; "
									f"district leader is {current_sup} (principal)"
								)
								print(f"  Replaced with SU superintendent: {su_super}")
							else:
								print(f"  Could not determine SU superintendent; keeping principal.")
						except Exception as su_err:
							print(f"  SU superintendent lookup failed: {su_err}")

					# Maine: many districts belong to school unions (SUs/RSUs)
					# even though NCES classifies them all as LEA_TYPE=1.
					# Trigger SU lookup when result is UNKNOWN, low/medium
					# confidence, or the person found is a principal.
					elif (state_abbr.upper() == "ME"
						and (current_sup.upper() == "UNKNOWN"
							or not current_sup
							or certainty in ("low", "medium")
							or (current_sup.upper() != "UNKNOWN" and current_sup
								and _is_principal_not_superintendent(final_answer, current_sup)))):
						is_principal = (current_sup.upper() != "UNKNOWN" and current_sup
							and _is_principal_not_superintendent(final_answer, current_sup))
						reason = "principal detected" if is_principal else (
							"UNKNOWN result" if current_sup.upper() == "UNKNOWN" or not current_sup
							else f"{certainty} confidence")
						print(f"  ME: {reason}; trying SU superintendent lookup...")
						try:
							su_name, su_super, su_certainty = _su_lookup_with_cache(
								su_cache, lea_name, state_name, state_abbr=state_abbr,
								city=city, lea_id=lea_id,
								principal_name=current_sup if current_sup.upper() != "UNKNOWN" else "",
							)
							if su_super and su_super.upper() != "UNKNOWN":
								should_replace = (
									current_sup.upper() == "UNKNOWN"
									or not current_sup
									or is_principal
									or CONFIDENCE_RANK.get(su_certainty, 0) >= CONFIDENCE_RANK.get(certainty, 0)
								)
								if should_replace:
									principal_note = (
										f"district leader is {current_sup} (principal)"
										if is_principal
										else ""
									)
									row_fields[4] = su_super
									certainty = su_certainty
									su_label = f" ({su_name})" if su_name and su_name.upper() != "UNKNOWN" else ""
									evidence_summary = f"SU superintendent{su_label}"
									if principal_note:
										evidence_summary += f"; {principal_note}"
									print(f"  Replaced with SU superintendent: {su_super}")
								else:
									print(f"  SU superintendent '{su_super}' found but not replacing "
										f"current '{current_sup}' ({certainty} confidence).")
							else:
								print(f"  Could not determine SU superintendent; keeping original result.")
						except Exception as su_err:
							print(f"  ME SU superintendent lookup failed: {su_err}")

					# NY LEA_TYPE=2: keep district superintendent, note chancellor in justification.
					if lea_type == "2" and state_abbr.upper() == "NY":
						if nyc_chancellor is None:
							print(f"  Looking up NYC Chancellor (first NY LEA_TYPE=2 district)...")
							try:
								_, nyc_chancellor, _ = ask_su_superintendent(
									lea_name, state_name, state_abbr=state_abbr,
									city=city, lea_id=lea_id,
								)
								if not nyc_chancellor or nyc_chancellor.upper() == "UNKNOWN":
									nyc_chancellor = ""
								else:
									nyc_chancellor, _ = _clean_superintendent_name(nyc_chancellor)
								print(f"  NYC Chancellor: {nyc_chancellor or 'UNKNOWN'}")
							except Exception as chan_err:
								print(f"  NYC Chancellor lookup failed: {chan_err}")
								nyc_chancellor = ""
						if nyc_chancellor:
							chan_note = f"NYC Chancellor: {nyc_chancellor}"
							if evidence_summary:
								evidence_summary = f"{evidence_summary}; {chan_note}"
							else:
								evidence_summary = chan_note

					# Capture pipeline justification before verification overwrites it.
					pipeline_name_for_just = (row_fields[4] or "UNKNOWN").strip()
					justification_main = f"{pipeline_name_for_just} ({certainty}): {evidence_summary}" if evidence_summary else f"{pipeline_name_for_just} ({certainty})"
					if unknown_reason and pipeline_name_for_just.upper() == "UNKNOWN":
						justification_main = f"UNKNOWN ({certainty}): {unknown_reason}"
					justification_verification = ""
					justification_judge = ""

					# Extract evidence signals from the final pipeline answer.
					final_parsed = parse_structured_superintendent_block(final_answer)
					ev = final_parsed.evidence

					# Independent cross-verification: do a fresh search
					# with all district data, then adjudicate between
					# the two results using a third model.
					pre_verify_name = (row_fields[4] or "").strip()
					if pre_verify_name:
						print(f"  Cross-verifying '{pre_verify_name}' independently...")
						try:
							v_name, v_conf, v_raw = _verify_superintendent_independently(
								pre_verify_name if pre_verify_name.upper() != "UNKNOWN" else "",
								lea_name, state_name,
								lea_id=lea_id, state_abbr=state_abbr,
								website=website, mailing_address=mailing_address,
								city=city, lea_type_text=lea_type_text,
								operational_schools=operational_schools,
							)
							logfile.write(
								f"{'='*60}\nLEAID={lea_id} | {district} | Verification\n{'='*60}\n"
								f"candidate={pre_verify_name} → verified={v_name}, confidence={v_conf}\n\n"
								f"{v_raw}\n\n")
							logfile.flush()
							v_parsed = parse_structured_superintendent_block(v_raw)
							justification_verification = (
								f"{v_name} ({v_conf}): {v_parsed.evidence_summary}"
								if v_parsed.evidence_summary
								else f"{v_name} ({v_conf})"
							)
							if v_parsed.unknown_reason and (not v_name or v_name.upper() == "UNKNOWN"):
								justification_verification = f"{v_name} ({v_conf}): {v_parsed.unknown_reason}"

							# Adjudicate between pipeline and verification.
							print(f"  Adjudicating between pipeline ('{pre_verify_name}', {certainty}) "
								  f"and verification ('{v_name}', {v_conf})...")
							try:
								adj_name, adj_conf, adj_note, adj_raw = _adjudicate_superintendent(
									pipeline_name=pre_verify_name,
									pipeline_confidence=certainty,
									pipeline_answer=final_answer,
									verification_name=v_name,
									verification_confidence=v_conf,
									verification_answer=v_raw,
									lea_name=lea_name, state_name=state_name,
									lea_id=lea_id, state_abbr=state_abbr,
									website=website, mailing_address=mailing_address,
									city=city, lea_type_text=lea_type_text,
									operational_schools=operational_schools,
								)
								logfile.write(
									f"{'='*60}\nLEAID={lea_id} | {district} | Adjudication\n{'='*60}\n"
									f"pipeline='{pre_verify_name}' ({certainty}), "
									f"verification='{v_name}' ({v_conf}) → "
									f"final='{adj_name}' ({adj_conf})\n{adj_note}\n\n"
									f"{adj_raw}\n\n")
								logfile.flush()

								adj_name_clean, _ = _clean_superintendent_name(adj_name)
								pipeline_cert = certainty
								best_cert = max(pipeline_cert, v_conf, key=lambda c: CONFIDENCE_RANK.get(c, 0))
								if adj_name_clean and adj_name_clean.upper() != "UNKNOWN":
									row_fields[4] = adj_name_clean
									certainty = best_cert
								else:
									row_fields[4] = "UNKNOWN"
									certainty = "low"
								justification_judge = f"{adj_name_clean or 'UNKNOWN'} ({adj_conf}): {adj_note}"
							except Exception as adj_err:
								print(f"  Adjudication failed: {adj_err}")
								pipeline_cert = certainty
								v_name_clean, _ = _clean_superintendent_name(v_name)
								v_name_upper = v_name_clean.upper()
								candidate_upper = pre_verify_name.upper()
								if v_name_upper != "UNKNOWN" and v_name_upper != candidate_upper:
									v_conf_rank = CONFIDENCE_RANK.get(v_conf, 0)
									cur_conf_rank = CONFIDENCE_RANK.get(certainty, 0)
									if v_conf_rank > cur_conf_rank:
										row_fields[4] = v_name_clean
										certainty = "medium"
								justification_judge = f"error ({adj_err}), fell back to confidence comparison"
						except Exception as v_err:
							print(f"  Cross-verification failed: {v_err}")
							justification_verification = f"error: {v_err}"

					clean_name, name_extras = _clean_superintendent_name(row_fields[4])
					row_fields[4] = clean_name
					if name_extras:
						justification_main = f"{name_extras}. {justification_main}" if justification_main else name_extras

					ev_fields = [
						"yes" if ev.found_on_district_website else "no",
						"yes" if ev.title_is_superintendent else "no",
						"yes" if ev.source_current_school_year else "no",
						"yes" if ev.multiple_sources_agree else "no",
						"yes" if ev.conflicting_info_found else "no",
						"yes" if ev.structural_uncertainty else "no",
						"yes" if ev.superintendent_transition else "no",
						"yes" if ev.district_website_accessible else "no",
					]
					out_fields = [row_fields[0], row_fields[2], row_fields[3], row_fields[4], row_fields[5], row_fields[7]]
					writer.writerow(out_fields + [certainty] + ev_fields + [justification_main, justification_verification, justification_judge])
				except Exception as e:
					print(f"Error processing {district} (LEAID={lea_id}): {e}")
					out_fields = [lea_id, lea_name, state_name, "UNKNOWN", "", ""]
					ev_fields = [""] * 8
					writer.writerow(out_fields + ["low"] + ev_fields + [f"Processing error: {e}", "", ""])

	end_time = datetime.now()
	elapsed = end_time - start_time
	print(f"\nRun completed at: {end_time.isoformat(timespec='seconds')}")
	print(f"Total time elapsed: {elapsed.total_seconds():.2f} seconds")
	print(f"Output written to: {results_filename}")
	print(f"Search log written to: {log_filename}")


if __name__ == "__main__":
	main()
