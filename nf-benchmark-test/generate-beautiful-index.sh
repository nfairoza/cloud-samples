#!/bin/bash

BUCKET_URL="$1"

if [ -z "$BUCKET_URL" ]; then
    echo "Usage: ./generate_index.sh s3://your-bucket-name/path"
    exit 1
fi

BUCKET=$(echo "$BUCKET_URL" | cut -d'/' -f3)
PREFIX=$(echo "$BUCKET_URL" | cut -d'/' -f4-)
BASE_URL="https://$BUCKET.s3.amazonaws.com"

# Use a temp file in current working directory
ALL_FILES="./all_files.txt"
OUTPUT="./index.html"

# Run AWS S3 list command and process the output
echo "Listing files from S3 bucket $BUCKET_URL..."
aws s3api list-objects-v2 \
    --bucket "$BUCKET" \
    --prefix "$PREFIX" \
    --query "Contents[].Key" \
    --output text | tr '\t' '\n' | sort > "$ALL_FILES"

# Start HTML
cat > "$OUTPUT" << 'EOF'
<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="UTF-8">
  <meta name="viewport" content="width=device-width, initial-scale=1.0">
  <title>AWS Compute Benchmark Explorer</title>
  <link rel="stylesheet" href="https://cdnjs.cloudflare.com/ajax/libs/font-awesome/6.0.0/css/all.min.css">
  <style>
    :root {
      --amd-red: #ed1c24;
      --amd-black: #000000;
      --netflix-red: #e50914;
      --netflix-black: #221f1f;
      --aws-blue: #232f3e;
      --aws-orange: #ff9900;

      --primary-color: var(--amd-red);
      --secondary-color: var(--netflix-red);
      --accent-color: var(--aws-orange);
      --dark-bg: var(--aws-blue);

      --text-color: #2b2d42;
      --text-light: #6c757d;
      --bg-color: #f8f9fa;
      --folder-bg: #f1f1f1;
      --folder-hover: #e3e3e3;
      --file-bg: #f8f9fa;
      --file-hover: #e9ecef;
      --border-radius: 6px;
      --transition: all 0.2s ease-in-out;
      --box-shadow: 0 2px 8px rgba(0,0,0,0.15);
    }

    * {
      margin: 0;
      padding: 0;
      box-sizing: border-box;
    }

    body {
      font-family: 'Segoe UI', Tahoma, Geneva, Verdana, sans-serif;
      line-height: 1.6;
      color: var(--text-color);
      background-color: var(--bg-color);
      padding: 0;
      margin: 0;
      background-image: url("data:image/svg+xml,%3Csvg width='60' height='60' viewBox='0 0 60 60' xmlns='http://www.w3.org/2000/svg'%3E%3Cg fill='none' fill-rule='evenodd'%3E%3Cg fill='%23232f3e' fill-opacity='0.05'%3E%3Cpath d='M36 34v-4h-2v4h-4v2h4v4h2v-4h4v-2h-4zm0-30V0h-2v4h-4v2h4v4h2V6h4V4h-4zM6 34v-4H4v4H0v2h4v4h2v-4h4v-2H6zM6 4V0H4v4H0v2h4v4h2V6h4V4H6z'/%3E%3C/g%3E%3C/g%3E%3C/svg%3E");
    }

    .container {
      max-width: 1200px;
      margin: 0 auto;
      padding: 0 1rem;
    }

    header {
      background: linear-gradient(135deg, var(--amd-red), var(--netflix-red));
      color: white;
      padding: 2.5rem 0;
      margin-bottom: 2rem;
      box-shadow: 0 4px 12px rgba(0,0,0,0.2);
      position: relative;
      overflow: hidden;
    }

    .header-bg {
      position: absolute;
      top: 0;
      left: 0;
      width: 100%;
      height: 100%;
      opacity: 0.1;
      background-image: url("data:image/svg+xml,%3Csvg width='100' height='100' viewBox='0 0 100 100' xmlns='http://www.w3.org/2000/svg'%3E%3Cpath d='M11 18c3.866 0 7-3.134 7-7s-3.134-7-7-7-7 3.134-7 7 3.134 7 7 7zm48 25c3.866 0 7-3.134 7-7s-3.134-7-7-7-7 3.134-7 7 3.134 7 7 7zm-43-7c1.657 0 3-1.343 3-3s-1.343-3-3-3-3 1.343-3 3 1.343 3 3 3zm63 31c1.657 0 3-1.343 3-3s-1.343-3-3-3-3 1.343-3 3 1.343 3 3 3zM34 90c1.657 0 3-1.343 3-3s-1.343-3-3-3-3 1.343-3 3 1.343 3 3 3zm56-76c1.657 0 3-1.343 3-3s-1.343-3-3-3-3 1.343-3 3 1.343 3 3 3zM12 86c2.21 0 4-1.79 4-4s-1.79-4-4-4-4 1.79-4 4 1.79 4 4 4zm28-65c2.21 0 4-1.79 4-4s-1.79-4-4-4-4 1.79-4 4 1.79 4 4 4zm23-11c2.76 0 5-2.24 5-5s-2.24-5-5-5-5 2.24-5 5 2.24 5 5 5zm-6 60c2.21 0 4-1.79 4-4s-1.79-4-4-4-4 1.79-4 4 1.79 4 4 4zm29 22c2.76 0 5-2.24 5-5s-2.24-5-5-5-5 2.24-5 5 2.24 5 5 5zM32 63c2.76 0 5-2.24 5-5s-2.24-5-5-5-5 2.24-5 5 2.24 5 5 5zm57-13c2.76 0 5-2.24 5-5s-2.24-5-5-5-5 2.24-5 5 2.24 5 5 5zm-9-21c1.105 0 2-.895 2-2s-.895-2-2-2-2 .895-2 2 .895 2 2 2zM60 91c1.105 0 2-.895 2-2s-.895-2-2-2-2 .895-2 2 .895 2 2 2zM35 41c1.105 0 2-.895 2-2s-.895-2-2-2-2 .895-2 2 .895 2 2 2zM12 60c1.105 0 2-.895 2-2s-.895-2-2-2-2 .895-2 2 .895 2 2 2z' fill='%23ffffff' fill-opacity='1' fill-rule='evenodd'/%3E%3C/svg%3E");
    }

    .brand-logos {
      position: absolute;
      bottom: 10px;
      right: 20px;
      display: flex;
      gap: 20px;
    }

    .brand-logo {
      height: 30px;
      filter: brightness(0) invert(1);
      opacity: 0.6;
    }

    header .container {
      display: flex;
      flex-direction: column;
      gap: 1rem;
      position: relative;
      z-index: 1;
    }

    h1 {
      margin: 0;
      font-size: 2.5rem;
      font-weight: 700;
      display: flex;
      align-items: center;
      gap: 15px;
    }

    .logo-icon {
      font-size: 2.2rem;
    }

    .subtitle {
      font-size: 1.2rem;
      opacity: 0.9;
      max-width: 700px;
    }

    .badge {
      display: inline-block;
      background-color: rgba(255, 255, 255, 0.2);
      padding: 4px 12px;
      border-radius: 20px;
      font-size: 0.9rem;
      font-weight: 500;
      margin-top: 10px;
      backdrop-filter: blur(5px);
    }

    .badge i {
      margin-right: 5px;
    }

    .controls-container {
      background-color: white;
      border-radius: var(--border-radius);
      padding: 1.5rem;
      margin-bottom: 2rem;
      box-shadow: var(--box-shadow);
      border-top: 4px solid var(--accent-color);
    }

    .search-container {
      margin-bottom: 1.5rem;
      position: relative;
    }

    #searchInput {
      width: 100%;
      padding: 12px 20px;
      padding-left: 40px;
      font-size: 1rem;
      border: 1px solid #ddd;
      border-radius: var(--border-radius);
      transition: var(--transition);
    }

    #searchInput:focus {
      outline: none;
      border-color: var(--primary-color);
      box-shadow: 0 0 0 3px rgba(237, 28, 36, 0.2);
    }

    .search-icon {
      position: absolute;
      left: 15px;
      top: 50%;
      transform: translateY(-50%);
      color: var(--text-light);
    }

    .controls {
      display: flex;
      gap: 10px;
      flex-wrap: wrap;
    }

    button {
      padding: 10px 20px;
      background-color: var(--accent-color);
      color: white;
      border: none;
      border-radius: var(--border-radius);
      cursor: pointer;
      font-size: 1rem;
      font-weight: 500;
      transition: var(--transition);
      display: flex;
      align-items: center;
      gap: 8px;
    }

    button:hover {
      background-color: var(--dark-bg);
      transform: translateY(-2px);
      box-shadow: 0 4px 8px rgba(0,0,0,0.2);
    }

    button:active {
      transform: translateY(0);
    }

    .file-explorer {
      background-color: white;
      border-radius: var(--border-radius);
      padding: 1.5rem;
      box-shadow: var(--box-shadow);
      border-top: 4px solid var(--primary-color);
      position: relative;
      overflow: hidden;
    }

    .explorer-bg {
      position: absolute;
      top: 0;
      right: 0;
      width: 200px;
      height: 200px;
      background-image: url("data:image/svg+xml,%3Csvg xmlns='http://www.w3.org/2000/svg' viewBox='0 0 80 80'%3E%3Cpath fill='%23ed1c24' fill-opacity='0.05' d='M14 16H9v-2h5V9.87a4 4 0 1 1 2 0V14h5v2h-5v15.95A10 10 0 0 0 23.66 27l-3.46-2 8.2-2.2-2.9 5a12 12 0 0 1-21 0l-2.89-5 8.2 2.2-3.47 2A10 10 0 0 0 14 31.95V16zm40 40h-5v-2h5v-4.13a4 4 0 1 1 2 0V54h5v2h-5v15.95A10 10 0 0 0 63.66 67l-3.47-2 8.2-2.2-2.88 5a12 12 0 0 1-21.02 0l-2.88-5 8.2 2.2-3.47 2A10 10 0 0 0 54 71.95V56zm-39 6a2 2 0 1 1 0-4 2 2 0 0 1 0 4zm40-40a2 2 0 1 1 0-4 2 2 0 0 1 0 4zM15 8a2 2 0 1 0 0-4 2 2 0 0 0 0 4zm40 40a2 2 0 1 0 0-4 2 2 0 0 0 0 4z'%3E%3C/path%3E%3C/svg%3E");
      opacity: 0.5;
      z-index: 0;
    }

    ul {
      list-style-type: none;
      padding-left: 1.5rem;
      margin: 0;
      position: relative;
      z-index: 1;
    }

    #tree {
      padding-left: 0;
    }

    li.folder > span {
      cursor: pointer;
      font-weight: 600;
      color: var(--text-color);
      display: flex;
      align-items: center;
      padding: 10px;
      margin: 3px 0;
      background-color: var(--folder-bg);
      border-radius: var(--border-radius);
      user-select: none;
      transition: var(--transition);
      border-left: 3px solid var(--secondary-color);
    }

    li.folder > span:hover {
      background-color: var(--folder-hover);
      transform: translateX(2px);
    }

    li.file > a {
      text-decoration: none;
      color: var(--text-color);
      display: flex;
      align-items: center;
      padding: 10px;
      margin: 3px 0;
      background-color: var(--file-bg);
      border-radius: var(--border-radius);
      transition: var(--transition);
    }

    li.file > a:hover {
      background-color: var(--file-hover);
      color: var(--primary-color);
      transform: translateX(2px);
    }

    .hidden {
      display: none;
    }

    .icon {
      display: inline-flex;
      align-items: center;
      justify-content: center;
      width: 24px;
      height: 24px;
      margin-right: 10px;
      color: var(--primary-color);
    }

    .file-icon {
      color: var(--accent-color);
    }

    .path-display {
      color: var(--text-light);
      font-size: 0.8rem;
      margin-left: 34px;
      margin-top: 2px;
      white-space: nowrap;
      overflow: hidden;
      text-overflow: ellipsis;
      max-width: 100%;
    }

    .loader {
      border: 3px solid #f3f3f3;
      border-radius: 50%;
      border-top: 3px solid var(--accent-color);
      width: 24px;
      height: 24px;
      animation: spin 1s linear infinite;
      margin: 2rem auto;
      display: none;
    }

    @keyframes spin {
      0% { transform: rotate(0deg); }
      100% { transform: rotate(360deg); }
    }

    footer {
      margin-top: 2rem;
      padding: 1.5rem 0;
      color: var(--text-light);
      font-size: 0.9rem;
      text-align: center;
      border-top: 1px solid #eee;
    }

    .file-info {
      display: flex;
      flex-direction: column;
    }

    .file-name {
      display: flex;
      align-items: center;
      gap: 8px;
    }

    /* Benchmark styling */
    .benchmark-tag {
      display: inline-block;
      padding: 2px 6px;
      border-radius: 4px;
      font-size: 0.7rem;
      font-weight: 600;
      margin-left: 8px;
      text-transform: uppercase;
      letter-spacing: 0.5px;
    }

    .benchmark-tag.amd {
      background-color: rgba(237, 28, 36, 0.15);
      color: var(--amd-red);
    }

    .benchmark-tag.netflix {
      background-color: rgba(229, 9, 20, 0.15);
      color: var(--netflix-red);
    }

    .benchmark-tag.aws {
      background-color: rgba(255, 153, 0, 0.15);
      color: var(--aws-orange);
    }

    /* Mobile responsive styles */
    @media (max-width: 768px) {
      h1 {
        font-size: 1.8rem;
      }

      .subtitle {
        font-size: 1rem;
      }

      button {
        padding: 8px 16px;
        font-size: 0.9rem;
      }

      .controls {
        flex-direction: column;
        gap: 8px;
      }

      .path-display {
        display: none;
      }

      .brand-logos {
        position: static;
        margin-top: 15px;
      }
    }

    /* Dark mode support */
    @media (prefers-color-scheme: dark) {
      :root {
        --text-color: #e9ecef;
        --text-light: #adb5bd;
        --bg-color: #212529;
        --folder-bg: #343a40;
        --folder-hover: #495057;
        --file-bg: #2b3035;
        --file-hover: #343a40;
      }

      body {
        background-color: var(--bg-color);
        background-image: url("data:image/svg+xml,%3Csvg width='60' height='60' viewBox='0 0 60 60' xmlns='http://www.w3.org/2000/svg'%3E%3Cg fill='none' fill-rule='evenodd'%3E%3Cg fill='%23ffffff' fill-opacity='0.03'%3E%3Cpath d='M36 34v-4h-2v4h-4v2h4v4h2v-4h4v-2h-4zm0-30V0h-2v4h-4v2h4v4h2V6h4V4h-4zM6 34v-4H4v4H0v2h4v4h2v-4h4v-2H6zM6 4V0H4v4H0v2h4v4h2V6h4V4H6z'/%3E%3C/g%3E%3C/g%3E%3C/svg%3E");
      }

      .controls-container, .file-explorer {
        background-color: #2b3035;
      }

      #searchInput {
        background-color: #343a40;
        color: var(--text-color);
        border-color: #495057;
      }

      footer {
        border-top-color: #343a40;
      }

      .benchmark-tag.amd {
        background-color: rgba(237, 28, 36, 0.25);
      }

      .benchmark-tag.netflix {
        background-color: rgba(229, 9, 20, 0.25);
      }

      .benchmark-tag.aws {
        background-color: rgba(255, 153, 0, 0.25);
      }
    }
  </style>
</head>
<body>


  <div class="container">
    <div class="controls-container">
      <div class="search-container">
        <i class="fas fa-search search-icon"></i>
        <input type="text" id="searchInput" placeholder="Search files and folders..." onkeyup="searchFiles()">
      </div>

      <div class="controls">
        <button onclick="toggleAll(true)">
          <i class="fas fa-expand-alt"></i> Expand All
        </button>
        <button onclick="toggleAll(false)">
          <i class="fas fa-compress-alt"></i> Collapse All
        </button>
        <button onclick="window.scrollTo({top: 0, behavior: 'smooth'})">
          <i class="fas fa-arrow-up"></i> Back to Top
        </button>
      </div>
    </div>

    <div class="file-explorer">
      <div id="loader" class="loader"></div>
      <ul id="tree">
EOF

# Python script to generate tree structure with better icons and organization
cat > ./tree_generator.py << 'PYEOF'
import sys
import os

def build_tree(file_list):
    tree = {}

    for path in file_list:
        path = path.strip()
        if not path:
            continue

        parts = path.split('/')
        current = tree

        for i, part in enumerate(parts):
            if not part:  # Skip empty parts
                continue

            if i == len(parts) - 1:  # Last part (file)
                current.setdefault('__files__', []).append((part, path))
            else:  # Directory
                if part not in current:
                    current[part] = {}
                current = current[part]

    return tree

def get_file_icon(filename):
    """Return an appropriate Font Awesome icon class based on file extension"""
    ext = filename.split('.')[-1].lower() if '.' in filename else ''

    icons = {
        # Documents
        'pdf': 'fa-file-pdf',
        'doc': 'fa-file-word', 'docx': 'fa-file-word',
        'xls': 'fa-file-excel', 'xlsx': 'fa-file-excel', 'csv': 'fa-file-csv',
        'ppt': 'fa-file-powerpoint', 'pptx': 'fa-file-powerpoint',
        'txt': 'fa-file-alt', 'rtf': 'fa-file-alt', 'md': 'fa-file-alt',

        # Images
        'jpg': 'fa-file-image', 'jpeg': 'fa-file-image', 'png': 'fa-file-image',
        'gif': 'fa-file-image', 'bmp': 'fa-file-image', 'svg': 'fa-file-image',

        # Archives
        'zip': 'fa-file-archive', 'rar': 'fa-file-archive', 'tar': 'fa-file-archive',
        'gz': 'fa-file-archive', '7z': 'fa-file-archive',

        # Audio
        'mp3': 'fa-file-audio', 'wav': 'fa-file-audio', 'ogg': 'fa-file-audio',

        # Video
        'mp4': 'fa-file-video', 'avi': 'fa-file-video', 'mov': 'fa-file-video',
        'wmv': 'fa-file-video', 'flv': 'fa-file-video',

        # Code
        'html': 'fa-file-code', 'css': 'fa-file-code', 'js': 'fa-file-code',
        'php': 'fa-file-code', 'py': 'fa-file-code', 'java': 'fa-file-code',
        'c': 'fa-file-code', 'cpp': 'fa-file-code', 'h': 'fa-file-code',
        'rb': 'fa-file-code', 'json': 'fa-file-code', 'xml': 'fa-file-code',
        'sql': 'fa-file-code', 'sh': 'fa-file-code', 'bash': 'fa-file-code',
    }

    return icons.get(ext, 'fa-file')

def print_tree(tree, base_url, indent=0):
    html = []

    # First process directories (sorted alphabetically)
    dirs = sorted([k for k in tree.keys() if k != '__files__'])
    for dir_name in dirs:
        html.append(f'''
        <li class="folder">
            <span onclick="toggleFolder(this)">
                <i class="icon fas fa-folder"></i> {dir_name}
            </span>
            <ul>
                {print_tree(tree[dir_name], base_url, indent + 1)}
            </ul>
        </li>''')

    # Then process files (sorted alphabetically)
    if '__files__' in tree:
        for file_name, file_path in sorted(tree['__files__'], key=lambda x: x[0].lower()):
            file_url = f"{base_url}/{file_path}"
            icon_class = get_file_icon(file_name)
            html.append(f'''
            <li class="file">
                <a href="{file_url}" onclick="return downloadFile('{file_url}')">
                    <i class="icon file-icon fas {icon_class}"></i>
                    <div class="file-info">
                        <div class="file-name">{file_name}</div>
                        <div class="path-display">{file_path}</div>
                    </div>
                </a>
            </li>''')

    return ''.join(html)

try:
    base_url = sys.argv[1]
    file_path = sys.argv[2]

    with open(file_path, 'r') as f:
        file_list = f.readlines()

    tree = build_tree(file_list)
    print(print_tree(tree, base_url))
except Exception as e:
    print(f'''<li class="file">
                <span style="color: #dc3545; padding: 10px; display: block;">
                    <i class="fas fa-exclamation-triangle" style="margin-right: 10px;"></i>
                    Error generating tree: {str(e)}
                </span>
             </li>''')
    print('''<li class="file">
                <span style="padding: 10px; display: block;">
                    <i class="fas fa-info-circle" style="margin-right: 10px;"></i>
                    Falling back to simple list...
                </span>
             </li>''')

    try:
        with open(file_path, 'r') as f:
            for line in sorted(f.readlines()):
                line = line.strip()
                if line:
                    filename = line.split('/')[-1]
                    url = f"{base_url}/{line}"
                    icon_class = get_file_icon(filename)
                    print(f'''<li class="file">
                              <a href="{url}" onclick="return downloadFile('{url}')">
                                <i class="icon file-icon fas {icon_class}"></i>
                                <div class="file-info">
                                  <div class="file-name">{filename}</div>
                                  <div class="path-display">{line}</div>
                                </div>
                              </a>
                            </li>''')
    except:
        print('''<li class="file">
                  <span style="color: #dc3545; padding: 10px; display: block;">
                    <i class="fas fa-exclamation-triangle" style="margin-right: 10px;"></i>
                    Could not generate file list
                  </span>
                </li>''')
PYEOF

# Execute the Python script to generate the tree - try python3 first, then python
python3 ./tree_generator.py "$BASE_URL" "$ALL_FILES" >> "$OUTPUT" 2>/dev/null || \
python ./tree_generator.py "$BASE_URL" "$ALL_FILES" >> "$OUTPUT" 2>/dev/null || \
echo "<li>Unable to generate tree structure. Please ensure Python is installed.</li>" >> "$OUTPUT"

# Close HTML
cat >> "$OUTPUT" << 'EOF'
      </ul>
    </div>
  </div>

  <footer>
    <div class="container">
      <p>Generated on: <span id="generation-time"></span></p>
      <p>Made with <i class="fas fa-heart" style="color: #ff4757;"></i> for S3 Bucket Organization</p>
    </div>
  </footer>

  <script>
    document.getElementById('generation-time').textContent = new Date().toLocaleString();

    function toggleFolder(element) {
      const folderIcon = element.querySelector('.icon');
      const ul = element.nextElementSibling;

      if (ul) {
        ul.classList.toggle('hidden');

        // Change folder icon
        if (ul.classList.contains('hidden')) {
          folderIcon.classList.remove('fa-folder-open');
          folderIcon.classList.add('fa-folder');
        } else {
          folderIcon.classList.remove('fa-folder');
          folderIcon.classList.add('fa-folder-open');
        }
      }
    }

    function toggleAll(expand = true) {
      document.getElementById('loader').style.display = 'block';

      // Use setTimeout to allow the UI to update before doing the expensive operation
      setTimeout(() => {
        document.querySelectorAll('li.folder > span + ul').forEach(ul => {
          ul.classList.toggle('hidden', !expand);

          // Update folder icons
          const folderIcon = ul.previousElementSibling.querySelector('.icon');
          if (!expand) {
            folderIcon.classList.remove('fa-folder-open');
            folderIcon.classList.add('fa-folder');
          } else {
            folderIcon.classList.remove('fa-folder');
            folderIcon.classList.add('fa-folder-open');
          }
        });

        document.getElementById('loader').style.display = 'none';
      }, 10);
    }

    function downloadFile(url) {
      const link = document.createElement('a');
      link.href = url;
      // Extract filename from URL for better download experience
      const filename = url.substring(url.lastIndexOf('/') + 1);
      link.setAttribute('download', filename);
      document.body.appendChild(link);
      link.click();
      document.body.removeChild(link);
      return false;
    }

    function searchFiles() {
      const searchTerm = document.getElementById('searchInput').value.toLowerCase();
      document.getElementById('loader').style.display = 'block';

      // Use setTimeout to allow the UI to update before doing the expensive operation
      setTimeout(() => {
        const allFiles = document.querySelectorAll('li.file');
        const allFolders = document.querySelectorAll('li.folder');

        // Reset visibility
        allFiles.forEach(file => file.style.display = '');
        allFolders.forEach(folder => folder.style.display = '');

        if (searchTerm.length < 2) {
          document.getElementById('loader').style.display = 'none';
          return; // Don't search for very short terms
        }

        // Hide non-matching files
        allFiles.forEach(file => {
          const fileName = file.textContent.toLowerCase();
          if (!fileName.includes(searchTerm)) {
            file.style.display = 'none';
          }
        });

        // Hide empty folders (no visible children) and expand folders with matching content
        allFolders.forEach(folder => {
          const visibleChildren = Array.from(folder.querySelectorAll('li'))
            .filter(child => child.style.display !== 'none').length;

          if (visibleChildren === 0) {
            folder.style.display = 'none';
          } else {
            // Expand folders with matching content
            const ul = folder.querySelector('ul');
            if (ul) {
              ul.classList.remove('hidden');
              // Update folder icon
              const folderIcon = folder.querySelector('span .icon');
              folderIcon.classList.remove('fa-folder');
              folderIcon.classList.add('fa-folder-open');
            }
          }
        });

        document.getElementById('loader').style.display = 'none';
      }, 10);
    }

    document.addEventListener('DOMContentLoaded', function() {
      // Initially collapse all folders except the first level
      document.querySelectorAll('li.folder > span + ul').forEach((ul, index, parent) => {
        if (ul.parentElement.parentElement.id !== 'tree') {
          ul.classList.add('hidden');
        }
      });

      // Set initial folder icons
      document.querySelectorAll('li.folder > span .icon').forEach(icon => {
        const ul = icon.closest('span').nextElementSibling;
        if (ul && ul.classList.contains('hidden')) {
          icon.classList.remove('fa-folder-open');
          icon.classList.add('fa-folder');
        } else {
          icon.classList.remove('fa-folder');
          icon.classList.add('fa-folder-open');
        }
      });

      // Add keyboard shortcut for search (Ctrl+F or Cmd+F)
      document.addEventListener('keydown', function(e) {
        if ((e.ctrlKey || e.metaKey) && e.key === 'f') {
          e.preventDefault();
          document.getElementById('searchInput').focus();
        }
      });
    });
  </script>
</body>
</html>
EOF

# Clean up the temporary Python file
rm -f ./tree_generator.py

echo "✅ Success: Beautiful S3 Bucket Explorer generated at: $OUTPUT"
echo "Open this file in your browser to navigate the S3 bucket structure"
echo "Features:"
echo "  • Modern, responsive design with dark mode support"
echo "  • File type recognition with appropriate icons"
echo "  • Improved search functionality"
echo "  • Smooth animations and visual feedback"
echo "  • Better mobile experience"
