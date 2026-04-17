#!/usr/bin/env python3
"""Convert final_report.md to PDF using markdown2 + xhtml2pdf."""

import os
import base64
import markdown2
from xhtml2pdf import pisa

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
REPO_ROOT = os.path.join(SCRIPT_DIR, "..")
MD_PATH = os.path.join(REPO_ROOT, "docs", "final_report.md")
PDF_PATH = os.path.join(REPO_ROOT, "docs", "final_report.pdf")
DOCS_DIR = os.path.join(REPO_ROOT, "docs")

with open(MD_PATH, encoding="utf-8") as f:
    md_text = f.read()

# Convert markdown to HTML
html_body = markdown2.markdown(
    md_text,
    extras=["tables", "fenced-code-blocks", "code-friendly", "header-ids"]
)

# Embed images as base64 data URIs for PDF compatibility
import re

def embed_image(match):
    src = match.group(1)
    width = match.group(2) if match.group(2) else ""
    # Resolve relative path from docs/
    img_path = os.path.normpath(os.path.join(DOCS_DIR, src))
    if os.path.exists(img_path):
        with open(img_path, "rb") as img_f:
            b64 = base64.b64encode(img_f.read()).decode()
        ext = os.path.splitext(img_path)[1].lower()
        mime = {"png": "image/png", "jpg": "image/jpeg", "jpeg": "image/jpeg"}.get(ext.strip("."), "image/png")
        # Convert percentage widths to fixed px for xhtml2pdf compatibility
        w = width
        if w and w.endswith("%"):
            pct = int(w.replace("%", ""))
            w = f"{int(736 * pct / 100)}px"  # A3 content width ~ 736px at 72dpi (11.7in - 1.5in margins)
        style = f'style="width:{w}; display:block; margin:8px auto;"' if w else 'style="max-width:736px; display:block; margin:8px auto;"'
        return f'<img src="data:{mime};base64,{b64}" {style} />'
    return match.group(0)

html_body = re.sub(r'<img\s+src="([^"]+)"(?:\s+width="([^"]+)")?\s*/?\s*>', embed_image, html_body)

full_html = f"""<!DOCTYPE html>
<html>
<head>
<meta charset="utf-8">
<style>
  @page {{
    size: A3;
    margin: 0.75in;
    @frame footer {{
      -pdf-frame-content: footerContent;
      bottom: 0cm;
      margin-left: 0.75in;
      margin-right: 0.75in;
      height: 1cm;
    }}
  }}
  body {{
    font-family: Georgia, "Times New Roman", serif;
    font-size: 10.5pt;
    line-height: 1.45;
    color: #1a1a1a;
  }}
  h1 {{
    font-size: 22pt;
    text-align: center;
    margin-top: 0;
    margin-bottom: 2pt;
    line-height: 1.3;
  }}
  h2 {{
    font-size: 14pt;
    border-bottom: 1.5pt solid #333;
    padding-bottom: 3pt;
    margin-top: 18pt;
  }}
  h3 {{
    font-size: 11.5pt;
    margin-top: 14pt;
  }}
  p {{
    margin: 5pt 0;
    text-align: justify;
  }}
  blockquote {{
    border-left: 3pt solid #999;
    padding-left: 10pt;
    margin-left: 0;
    font-style: italic;
    color: #333;
  }}
  table {{
    border-collapse: collapse;
    width: 100%;
    font-size: 9pt;
    margin: 6pt 0;
  }}
  th, td {{
    border: 0.5pt solid #999;
    padding: 3pt 5pt;
    text-align: left;
  }}
  th {{
    background-color: #f0f0f0;
    font-weight: bold;
  }}
  code {{
    font-family: Consolas, "Courier New", monospace;
    font-size: 9pt;
    background-color: #f5f5f5;
    padding: 1pt 2pt;
  }}
  pre {{
    background-color: #f5f5f5;
    padding: 6pt 10pt;
    font-size: 8.5pt;
    line-height: 1.25;
    overflow: hidden;
  }}
  pre code {{
    background: none;
    padding: 0;
  }}
  img {{
    max-width: 80%;
    display: block;
    margin: 6pt auto;
    border: 1pt solid #ccc;
    padding: 6pt;
    background: #fafafa;
  }}
  em {{
    font-style: italic;
  }}
  hr {{
    border: none;
    border-top: 0.5pt solid #ccc;
    margin: 12pt 0;
  }}
</style>
</head>
<body>
{html_body}
<div id="footerContent" style="text-align:center; font-size:9pt; color:#666;">
  Page <pdf:pagenumber /> of <pdf:pagecount />
</div>
</body>
</html>
"""

print(f"Converting {MD_PATH} to PDF...")
with open(PDF_PATH, "wb") as pdf_f:
    status = pisa.CreatePDF(full_html, dest=pdf_f)

if status.err:
    print(f"Errors during conversion: {status.err}")
else:
    size_kb = os.path.getsize(PDF_PATH) / 1024
    print(f"Saved: {PDF_PATH}")
    print(f"Size: {size_kb:.0f} KB")
    print("Done.")
