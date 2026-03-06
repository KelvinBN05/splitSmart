# SplitSmart

SplitSmart is an iOS app for scanning and splitting receipts across friends. This repo currently includes a polished SwiftUI home experience, a split calculation engine, and unit tests for money allocation.

## Current Features (Phase 1)

- Home dashboard modeled after modern finance/productivity apps
- Receipt domain models (`Receipt`, `ReceiptItem`, `Participant`)
- Split calculator for:
  - item ownership allocation
  - proportional tax distribution
  - proportional tip distribution
  - cent-level rounding safety
- Unit tests for split behavior and total validation

## Project Structure

- `ReceiptSplitter/ContentView.swift`: main tabs + home/history/profile UI
- `ReceiptSplitter/Models/`: core data models for receipt splitting
- `ReceiptSplitter/Services/SplitCalculator.swift`: split engine and allocation rules
- `ReceiptSplitterTests/SplitCalculatorTests.swift`: unit tests for split math

## Next Milestones

1. OCR scanning flow (VisionKit + text parsing)
2. Manual correction screen for OCR mistakes
3. Save/load receipts with persistence
4. Export/share split summary

## Run

1. Open `ReceiptSplitter.xcodeproj` in Xcode
2. Select an iOS Simulator
3. Build and run (`Cmd + R`)

## Test

Run tests in Xcode (`Cmd + U`) or with:

```bash
xcodebuild test -project ReceiptSplitter.xcodeproj -scheme ReceiptSplitter -destination 'platform=iOS Simulator,name=iPhone 16'
```

## Backend OCR (Document AI)

This project now uses a backend OCR job flow for receipt parsing:

1. iOS uploads image to Storage under `users/{uid}/ocrUploads/{jobId}.jpg`
2. iOS creates Firestore doc `users/{uid}/ocrJobs/{jobId}`
3. Cloud Function `processOCRJob` calls Document AI and writes parsed fields to `result`
4. iOS polls job status, opens a Review OCR screen, then opens Manual Entry with prefilled fields

### OCR review behavior

- Edit OCR item `name`, `qty`, `price` inline
- Quick delete rows
- Optional `Mark as discount` toggle to exclude lines before manual entry
- Saved receipts include `sourceOCRJobID` for traceability/debugging

## Collaboration Shell (Step 1 + 2)

The app now supports creating a collaboration session from a saved receipt:

- Firestore path: `users/{uid}/splitSessions/{sessionId}`
- Session payload includes:
  - owner identity
  - source receipt id (+ optional OCR job id)
  - members (starts with owner)
  - receipt items mapped for assignment
  - totals snapshot
- In-app trigger: History tab -> `Create Session` button per receipt

### One-time setup

1. Create a Document AI receipt processor in Google Cloud
2. Note:
   - `DOCUMENT_AI_PROJECT_ID`
   - `DOCUMENT_AI_LOCATION` (e.g. `us`)
   - `DOCUMENT_AI_PROCESSOR_ID`

### Deploy

```bash
cd "/Users/kelvinnguyen/Documents/Projects/Receipt App/splitSmart/functions"
npm install

cd "/Users/kelvinnguyen/Documents/Projects/Receipt App/splitSmart"
firebase functions:config:set \
  document_ai.project_id="recieptsplitter" \
  document_ai.location="us" \
  document_ai.processor_id="YOUR_PROCESSOR_ID"

cd "/Users/kelvinnguyen/Documents/Projects/Receipt App/splitSmart"
firebase deploy --only firestore:rules,storage,functions --project recieptsplitter
```

### Parser regression tests

```bash
cd "/Users/kelvinnguyen/Documents/Projects/Receipt App/splitSmart/functions"
npm test
```
