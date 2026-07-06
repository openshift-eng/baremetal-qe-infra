#!/usr/bin/env python3
import os
import csv
import sys
import shutil
import zipfile
from pathlib import Path

import uvicorn
from fastapi import FastAPI, UploadFile, Form
from fastapi.responses import JSONResponse, FileResponse
from fastapi.middleware.cors import CORSMiddleware
from google.oauth2 import service_account
from googleapiclient.discovery import build


app = FastAPI()

app.add_middleware(CORSMiddleware, allow_origins=["*"], allow_methods=["*"], allow_headers=["*"])

WORKSPACE_DIR = Path("/usr/share/sync-bm-capacity-tracker")
STORAGE_DIR = Path("/var/mnt/data-storage/sync-bm-capacity-tracker")

UPLOAD_DIR = STORAGE_DIR / "uploaded-packages"
UPLOAD_DIR.mkdir(parents=True, exist_ok=True)

SCOPES = ['https://www.googleapis.com/auth/spreadsheets']
DEFAULT_AMD64_SHEET_ID = "1hDOqRCRZ0Q-hro1RF29sAtChjSN3hUMLDobHxiulVWE"
DEFAULT_ARM64_SHEET_ID = "1r4cCmJ83OIkdlzgmJ2fy2nWgA6wtzFxydfArb5mpKjg"


def get_credentials_from_env():
    """Reads the service account key path from the standard GOOGLE_APPLICATION_CREDENTIALS environment variable."""
    env_var = "GOOGLE_APPLICATION_CREDENTIALS"
    path_str = os.environ.get(env_var)

    if not path_str or not Path(path_str).exists():
        print(f"❌ Error: Valid key path missing in env '{env_var}'!")
        sys.exit(1)

    try:
        return service_account.Credentials.from_service_account_file(path_str, scopes=SCOPES)
    except Exception:
        print(f"❌ Error: Failed to parse credentials file.")
        sys.exit(1)


GLOBAL_CREDS = get_credentials_from_env()
GLOBAL_SERVICE = build('sheets', 'v4', credentials=GLOBAL_CREDS, cache_discovery=False)

def get_sheet_id_mapping(service, spreadsheet_id):
    """Fetches spreadsheet metadata to build a runtime title-to-id dictionary map once."""
    try:
        meta = service.spreadsheets().get(spreadsheetId=spreadsheet_id).execute()
        return {s['properties']['title']: s['properties']['sheetId'] for s in meta.get('sheets', [])}
    except Exception:
        print(f"❌ Error: Failed to fetch spreadsheet metadata.")
        sys.exit(1)


def get_sheets_metadata(service, spreadsheet_id):
    """Fetches full spreadsheet metadata to track properties, sheet IDs, and layout titles."""
    try:
        return service.spreadsheets().get(spreadsheetId=spreadsheet_id).execute()
    except Exception as e:
        raise Exception(f"Failed to fetch spreadsheet metadata: {str(e)}")


def parse_version(title: str) -> list:
    """Extracts numerical segments out of standard strings like '4.14 Jobs' or '5.2 Jobs'."""
    import re
    match = re.search(r'([0-9.]+)', title)
    if match:
        try:
            return [int(x) for x in match.group(1).split('.')]
        except ValueError:
            pass
    return [0]


def reconcile_spreadsheet_tabs(service, spreadsheet_id, tsv_file_stems):
    """Deletes abandoned Jobs tabs, spawns missing ones, and reorders them sequentially."""
    meta = get_sheets_metadata(service, spreadsheet_id)
    sheets = meta.get('sheets', [])

    current_sheet_map = {s['properties']['title']: s['properties']['sheetId'] for s in sheets}
    template_sheet_id = current_sheet_map.get('Job_Template')

    if template_sheet_id is None:
        print("⚠️ Warning: 'template' tab not discovered. Falling back to blank layouts.")

    delete_requests = []
    active_titles = list(current_sheet_map.keys())
    for title in active_titles:
        if "Jobs" in title and title not in tsv_file_stems:
            print(f"🗑️ Deleting stale tab: '{title}'")
            delete_requests.append({"deleteSheet": {"sheetId": current_sheet_map[title]}})
            del current_sheet_map[title]

    if delete_requests:
        service.spreadsheets().batchUpdate(spreadsheetId=spreadsheet_id, body={"requests": delete_requests}).execute()

    creation_requests = []
    for stem in tsv_file_stems:
        if stem not in current_sheet_map:
            if template_sheet_id is not None:
                print(f"✨ Spawning new tab from template structure: '{stem}'")
                creation_requests.append({
                    "duplicateSheet": {
                        "sourceSheetId": template_sheet_id,
                        "newSheetName": stem,
                        "insertSheetIndex": len(current_sheet_map)
                    }
                })
            else:
                print(f"➕ Spawning blank layout tab for: '{stem}'")
                creation_requests.append({"addSheet": {"properties": {"title": stem}}})

    if creation_requests:
        service.spreadsheets().batchUpdate(spreadsheetId=spreadsheet_id, body={"requests": creation_requests}).execute()

    meta = get_sheets_metadata(service, spreadsheet_id)
    all_sheets = meta.get('sheets', [])

    static_pages = [s for s in all_sheets if "Jobs" not in s['properties']['title']]
    version_pages = [s for s in all_sheets if "Jobs" in s['properties']['title']]

    version_pages.sort(key=lambda s: parse_version(s['properties']['title']))

    ordered_sheets = static_pages + version_pages

    reorder_requests = []
    for index, sheet_obj in enumerate(ordered_sheets):
        reorder_requests.append({
            "updateSheetProperties": {
                "properties": {
                    "sheetId": sheet_obj['properties']['sheetId'],
                    "index": index
                },
                "fields": "index"
            }
        })

    if reorder_requests:
        service.spreadsheets().batchUpdate(spreadsheetId=spreadsheet_id, body={"requests": reorder_requests}).execute()

        meta = get_sheets_metadata(service, spreadsheet_id)
        sheets = meta.get('sheets', [])
        current_sheet_map = {s['properties']['title']: s['properties']['sheetId'] for s in sheets}

    return current_sheet_map


def apply_borders_and_clear(service, spreadsheet_id, sheet_id, total_rows, max_cols):
    """Clears old formatting/cells and draws clean grid borders using a compact batch request."""
    style = {"style": "SOLID", "color": {"red": 0.0, "green": 0.0, "blue": 0.0, "alpha": 1.0}}
    box_range = {"sheetId": sheet_id, "startRowIndex": 1, "endRowIndex": 1 + total_rows, "startColumnIndex": 0, "endColumnIndex": max_cols}

    body = {
        "requests": [
            {"updateCells": {"range": {"sheetId": sheet_id, "startRowIndex": 1}, "fields": "userEnteredValue,userEnteredFormat"}},
            {"updateBorders": {"range": box_range, "top": style, "bottom": style, "left": style, "right": style, "innerHorizontal": style, "innerVertical": style}}
        ]
    }
    service.spreadsheets().batchUpdate(spreadsheetId=spreadsheet_id, body=body).execute()


def process_tsv_file(service, spreadsheet_id, sheet_id_map, tsv_file_path):
    """Reads TSV, clears old context, updates new cells, applies borders and records audit logs."""
    tab_title = tsv_file_path.stem

    if tab_title not in sheet_id_map:
        print(f"❌ {tab_title} skip as the sheet not found")
        return f"Skipped tab '{tab_title}' (not found in Google Sheets)"

    rows_to_upload = []
    max_cols = 0
    with open(tsv_file_path, "r", encoding="utf-8", errors="ignore") as f:
        for row in csv.reader(f, delimiter="\t"):
            rows_to_upload.append(row)
            max_cols = max(max_cols, len(row))

    if not rows_to_upload:
        print(f"⚠️ Skipping empty file: {tsv_file_path.name}")
        return f"Skipped empty file {tsv_file_path.name}"

    apply_borders_and_clear(service, spreadsheet_id, sheet_id_map[tab_title], len(rows_to_upload), max_cols)

    service.spreadsheets().values().update(
        spreadsheetId=spreadsheet_id,
        range=f"'{tab_title}'!A2",
        valueInputOption='USER_ENTERED',
        body={'values': rows_to_upload}
    ).execute()

    print(f"🚀 Successfully synced {len(rows_to_upload)} rows into tab '{tab_title}'")
    return f"Synced {len(rows_to_upload)} rows into tab '{tab_title}'"


@app.get("/sync-bm-tracker")
def serve_dashboard_ui():
    """Serves the frontend static index web page file natively."""
    html_file = WORKSPACE_DIR / "index.html"
    if not html_file.exists():
        return JSONResponse(status_code=404, content={"status": "error", "message": "index.html template missing."})
    return FileResponse(html_file)


@app.post("/sync-bm-tracker/api/sync-bm-capacity-tracker")
def trigger_sync_pipeline(
        arch: str = Form(...),
        username: str = Form(...),
        tsv_zip: UploadFile = Form(...)
):
    try:
        if arch == "amd64":
            sheet_id = DEFAULT_AMD64_SHEET_ID
        elif arch == "arm64":
            sheet_id = DEFAULT_ARM64_SHEET_ID
        else:
            return JSONResponse(status_code=400, content={"status": "error", "message": "Unsupported architecture choice."})

        zip_path = UPLOAD_DIR / tsv_zip.filename
        with zip_path.open("wb") as buffer:
            buffer.write(tsv_zip.file.read())

        extract_target = UPLOAD_DIR / arch
        if extract_target.exists():
            shutil.rmtree(extract_target)
        extract_target.mkdir(parents=True, exist_ok=True)

        with zipfile.ZipFile(zip_path, 'r') as zip_ref:
            zip_ref.extractall(extract_target)

        creds = get_credentials_from_env()
        service = build('sheets', 'v4', credentials=creds, cache_discovery=False)
        get_sheet_id_mapping(service, sheet_id)

        tsv_files = sorted(list(extract_target.rglob("*.tsv")))
        tsv_file_stems = [f.stem for f in tsv_files if "Jobs" in f.stem]

        if not tsv_files:
            return JSONResponse(status_code=400, content={"status": "error", "message": "No functional .tsv files found inside ZIP package."})

        sheet_id_map = reconcile_spreadsheet_tabs(service, sheet_id, tsv_file_stems)

        log_summary = []
        for tsv_path in tsv_files:
            process_tsv_file(service, sheet_id, sheet_id_map, tsv_path)

        if zip_path.exists():
            shutil.rmtree(extract_target)

        return JSONResponse(content={
            "status": "success",
            "message": f"BM Tracker Synced! Dataset successfully updated by user '{username}'.",
            "details": log_summary
        })

    except Exception as e:
        return JSONResponse(status_code=500, content={"status": "error", "message": f"Sync failure: {str(e)}"})


if __name__ == "__main__":
    uvicorn.run("server:app", host="0.0.0.0", port=8080, reload=False)