# Project 3 - Data Management

## Setup

1. Start Container

   ```bash
   docker compose up -d
   ```

## Seed Data
1. Make sure database Postgres dari project 2 sudah aktif

2. Copy env Variable

   ```bash
   cp .env.example .env  
   ```

2. Seed data

   ```bash
   python scripts/seed.py
   ```

## Python Environment

1. Virtual environment

   ```bash
   python -m venv .venv
   ```

2. Aktivasi

   ```bash
   # Windows (PowerShell)
   .\.venv\Scripts\Activate.ps1

   # macOS / Linux
   source .venv/bin/activate
   ```

3. Install dependencies

   ```bash
   pip install -r requirements.txt
   ```