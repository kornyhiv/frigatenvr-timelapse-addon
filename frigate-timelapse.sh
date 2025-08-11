#!/bin/bash

# ==============================================================================
# Frigate Timelapse Addon Script
#
# Author: Gemini
# Version: 14.1 
# ==============================================================================

# Color definitions for professional output
COLOR_RESET=$'\e[0m'
COLOR_BOLD=$'\e[1m'
COLOR_GREEN=$'\e[32m'
COLOR_YELLOW=$'\e[33m'
COLOR_RED=$'\e[31m'
COLOR_HEADER=$'\e[1;33m'
COLOR_INFO=$'\e[32m'
COLOR_SUCCESS=$'\e[1;32m'
COLOR_WARN=$'\e[33m'
COLOR_PROMPT=$'\e[33m'
COLOR_ERROR=$'\e[31m'

# Function for section headers
section_header() {
    echo -e "\n${COLOR_HEADER}================================================================================${COLOR_RESET}" >&2
    echo -e "${COLOR_HEADER} $1 ${COLOR_RESET}" >&2
    echo -e "${COLOR_HEADER}================================================================================${COLOR_RESET}\n" >&2
}

success_msg() { echo -e "${COLOR_SUCCESS}[SUCCESS] $1${COLOR_RESET}" >&2; }
info_msg() { echo -e "${COLOR_INFO}[INFO] $1${COLOR_RESET}" >&2; }
warn_msg() { echo -e "${COLOR_WARN}[WARNING] $1${COLOR_RESET}" >&2; }
error_msg() { echo -e "${COLOR_ERROR}[ERROR] $1${COLOR_RESET}" >&2; }

# --- Script Configuration ---
ADDON_DIR="./frigate_timelapse_addon"
DOCKER_IMAGE_NAME="frigate-timelapse-addon"
DOCKER_CONTAINER_NAME="frigate-timelapse"
FRIGATE_CONTAINER_NAME="frigate"
ADDON_PORT="5005"

# --- Helper Functions ---
check_dependencies() {
    section_header "Checking Dependencies"
    local missing_deps=0

    for cmd in docker jq lspci wget openssl; do
        if ! command -v "$cmd" &>/dev/null; then
            error_msg "'$cmd' is not installed. Please install it using your system's package manager (e.g., 'sudo apt-get install $cmd')."
            missing_deps=1
        else
            success_msg "'$cmd' is installed."
        fi
    done

    if [ "$missing_deps" -eq 1 ]; then exit 1; fi

    if ! command -v yq &>/dev/null; then
        warn_msg "'yq' is not installed. Attempting to install it automatically..."
        if wget https://github.com/mikefarah/yq/releases/latest/download/yq_linux_amd64 -O /usr/bin/yq && chmod +x /usr/bin/yq; then
            success_msg "'yq' has been installed successfully."
        else
            error_msg "Failed to automatically install 'yq'. Please install it manually and re-run the script."
            info_msg "Manual install command: sudo wget https://github.com/mikefarah/yq/releases/latest/download/yq_linux_amd64 -O /usr/bin/yq && sudo chmod +x /usr/bin/yq"
            exit 1
        fi
    else
        success_msg "'yq' is installed."
    fi
}

detect_hardware() {
    section_header "Detecting Hardware Acceleration"
    HWACCEL_TYPE="cpu"
    DOCKER_HW_FLAGS=""
    if lspci | grep -iq 'vga.*nvidia'; then
        info_msg "NVIDIA GPU detected."
        if ! command -v nvidia-smi &>/dev/null; then
            warn_msg "NVIDIA GPU detected, but 'nvidia-smi' is not found. Cannot use for hardware acceleration."
        else
            success_msg "NVIDIA drivers appear to be installed. Enabling GPU acceleration."
            HWACCEL_TYPE="nvidia"
            DOCKER_HW_FLAGS="--gpus all"
        fi
    elif lspci | grep -iq 'vga.*intel'; then
        info_msg "Intel GPU detected."
        if [ -d "/dev/dri" ]; then
            success_msg "Intel iGPU detected. Enabling QSV acceleration."
            HWACCEL_TYPE="intel_qsv"
            DOCKER_HW_FLAGS="--device=/dev/dri:/dev/dri"
        else
            warn_msg "Intel GPU detected, but /dev/dri does not exist."
        fi
    else
        info_msg "No NVIDIA or Intel GPU detected. Using CPU for encoding."
    fi
}

find_frigate_paths() {
    section_header "Locating Frigate Directories"
    info_msg "Inspecting the '${FRIGATE_CONTAINER_NAME}' container to find volume paths..."
    if ! docker ps -a --format '{{.Names}}' | grep -q "^${FRIGATE_CONTAINER_NAME}$"; then error_msg "Frigate container '${FRIGATE_CONTAINER_NAME}' not found."; exit 1; fi

    FRIGATE_CONFIG_PATH=$(docker container inspect ${FRIGATE_CONTAINER_NAME} | jq -r '.[0].Mounts[] | select(.Destination == "/config") | .Source')
    if [ -z "$FRIGATE_CONFIG_PATH" ]; then error_msg "Could not find Frigate's '/config' volume mount."; exit 1; fi
    success_msg "Found Frigate config host path: ${FRIGATE_CONFIG_PATH}"

    local config_file
    if [ -f "${FRIGATE_CONFIG_PATH}/config.yml" ]; then
        config_file="${FRIGATE_CONFIG_PATH}/config.yml"
    elif [ -f "${FRIGATE_CONFIG_PATH}/config.yaml" ]; then
        config_file="${FRIGATE_CONFIG_PATH}/config.yaml"
    else
        error_msg "Could not find config.yml or config.yaml in ${FRIGATE_CONFIG_PATH}"; exit 1
    fi
    success_msg "Using config file: ${config_file}"

    local record_path_from_config
    record_path_from_config=$(yq e '.record.path' "$config_file")

    local recordings_container_path
    if [ -z "$record_path_from_config" ] || [ "$record_path_from_config" == "null" ]; then
        info_msg "Recordings path not specified in config.yml, using default 'frigate/recordings'."
        recordings_container_path="/media/frigate/recordings"
    else
        if [[ "$record_path_from_config" == /* ]]; then
            info_msg "Detected absolute recordings path in config.yml: ${record_path_from_config}"
            recordings_container_path="$record_path_from_config"
        else
            info_msg "Detected relative recordings path in config.yml: ${record_path_from_config}"
            recordings_container_path="/media/${record_path_from_config}"
        fi
    fi
    info_msg "Resolved full recordings path inside Frigate container: ${recordings_container_path}"

    local best_match_dest=""
    local best_match_src=""
    
    while IFS= read -r line; do
        local dest
        dest=$(echo "$line" | jq -r '.Destination')
        
        if [[ "$recordings_container_path" == "${dest}"* ]]; then
            if [ ${#dest} -gt ${#best_match_dest} ]; then
                best_match_dest="$dest"
                best_match_src=$(echo "$line" | jq -r '.Source')
            fi
        fi
    done < <(docker container inspect ${FRIGATE_CONTAINER_NAME} | jq -c '.[0].Mounts[]')

    if [ -z "$best_match_dest" ]; then
        error_msg "Fatal: Could not find any volume mount that contains the recordings path '${recordings_container_path}'."
        exit 1
    fi

    local sub_path="${recordings_container_path#$best_match_dest}"
    FRIGATE_RECORDINGS_PATH_HOST="${best_match_src}${sub_path}"

    if [ ! -d "$FRIGATE_RECORDINGS_PATH_HOST" ]; then
        warn_msg "Auto-detected recordings host path does not exist: ${FRIGATE_RECORDINGS_PATH_HOST}"
        warn_msg "This may be okay if Frigate has not created it yet. Proceeding with caution."
    else
        success_msg "Successfully mapped to recordings host path: ${COLOR_BOLD}${FRIGATE_RECORDINGS_PATH_HOST}${COLOR_RESET}"
    fi
}


# --- Main Application Logic ---
create_addon_files() {
    section_header "Creating Timelapse Application Files"
    info_msg "Creating directory and files at ${ADDON_DIR}"
    mkdir -p "${ADDON_DIR}/templates"
    mkdir -p "${ADDON_DIR}/timelapses/thumbnails"
    mkdir -p "${ADDON_DIR}/certs"

    if [ ! -f "${ADDON_DIR}/certs/key.pem" ] || [ ! -f "${ADDON_DIR}/certs/cert.pem" ]; then
        info_msg "Generating self-signed certificate for HTTPS..."
        openssl req -x509 -newkey rsa:4096 -nodes \
            -keyout "${ADDON_DIR}/certs/key.pem" \
            -out "${ADDON_DIR}/certs/cert.pem" \
            -sha256 -days 3650 \
            -subj "/C=US/ST=State/L=City/O=Frigate/OU=Timelapse/CN=localhost"
        success_msg "Certificate generated."
    else
        info_msg "Existing certificate found. Skipping generation."
    fi

    cat <<'EOF' > "${ADDON_DIR}/Dockerfile"
FROM jrottenberg/ffmpeg:7.1-nvidia2204
WORKDIR /app
RUN apt-get clean && \
    apt-get update -o Acquire::Check-Valid-Until=false -o Acquire::Check-Date=false && \
    apt-get install -y --no-install-recommends python3 python3-pip && \
    apt-get clean && \
    rm -rf /var/lib/apt/lists/*
RUN pip3 install --no-cache-dir Flask PyYAML
COPY . .
ENTRYPOINT ["python3", "app.py"]
EOF
    success_msg "Created Dockerfile."

    cat <<EOF > "${ADDON_DIR}/app.py"
import os
import yaml
import subprocess
import re
import uuid
import threading
import time
import signal
from flask import Flask, jsonify, request, render_template, send_from_directory
from glob import glob
import logging
from collections import deque
import shlex

app = Flask(__name__)
logging.basicConfig(level=logging.INFO)

JOBS = {}
JOBS_LOCK = threading.Lock()

CONFIG_DIR = '/config'
FRIGATE_RECORDINGS_PATH = '/recordings' 
TIMELAPSE_OUTPUT_PATH = '/app/timelapses'
TIMELAPSE_THUMBNAIL_PATH = '/app/timelapses/thumbnails'
HWACCEL_TYPE = os.environ.get('HWACCEL_TYPE', 'cpu')
CERT_FILE = '/app/certs/cert.pem'
KEY_FILE = '/app/certs/key.pem'
APP_PORT = int(os.environ.get('APP_PORT', ${ADDON_PORT}))

def get_video_duration(filepath):
    cmd = ['ffprobe', '-v', 'error', '-show_entries', 'format=duration', '-of', 'default=noprint_wrappers=1:nokey=1', filepath]
    try:
        result = subprocess.run(cmd, capture_output=True, text=True, check=True)
        return float(result.stdout)
    except Exception: return 0.0

def get_frigate_data():
    cameras = {}
    config_path = None
    if os.path.exists(os.path.join(CONFIG_DIR, 'config.yml')): config_path = os.path.join(CONFIG_DIR, 'config.yml')
    elif os.path.exists(os.path.join(CONFIG_DIR, 'config.yaml')): config_path = os.path.join(CONFIG_DIR, 'config.yaml')
    if not config_path: return {"error": "config.yml or config.yaml not found"}
    try:
        with open(config_path, 'r') as f: config = yaml.safe_load(f)
        camera_names = list(config.get('cameras', {}).keys())
    except Exception as e: return {"error": str(e)}
    for name in camera_names: cameras[name] = set()
    if not os.path.isdir(FRIGATE_RECORDINGS_PATH): return {"error": f"Recordings directory not found at {FRIGATE_RECORDINGS_PATH}"}
    for date_folder in os.listdir(FRIGATE_RECORDINGS_PATH):
        date_path = os.path.join(FRIGATE_RECORDINGS_PATH, date_folder)
        if not os.path.isdir(date_path) or not re.match(r'^\d{4}-\d{2}-\d{2}$', date_folder): continue
        for hour_folder in os.listdir(date_path):
            hour_path = os.path.join(date_path, hour_folder)
            if not os.path.isdir(hour_path): continue
            for camera_folder in os.listdir(hour_path):
                if camera_folder in cameras: cameras[camera_folder].add(date_folder)
    for camera in cameras: cameras[camera] = sorted(list(cameras[camera]), reverse=True)
    return {k: v for k, v in cameras.items() if v}

def ffmpeg_worker(job_id, params):
    process = None
    list_file_path = f'/tmp/{job_id}-filelist.txt'
    file_list_content = ""
    ffmpeg_cmd_str = ""
    total_duration = 0
    log_output = [] 
    try:
        camera, date, speed_factor = params['camera'], params['date'], params['speed']
        start_hour, end_hour = params['startHour'], params['endHour']
        use_nvenc = params.get('use_nvenc', False)

        app.logger.info(f"[{job_id}] Worker started. Finding video files...")
        glob_pattern = os.path.join(FRIGATE_RECORDINGS_PATH, date, '*', camera, '*.mp4')
        filtered_files = [f for f in sorted(glob(glob_pattern)) if start_hour <= int(os.path.basename(os.path.dirname(os.path.dirname(f)))) <= end_hour]

        if not filtered_files: raise ValueError("No video files found in the selected time range.")
        
        with open(list_file_path, 'w') as f:
            for video_file in filtered_files: f.write(f"file '{video_file}'\\n")
        
        with open(list_file_path, 'r') as f:
            file_list_content = f.read()

        app.logger.info(f"[{job_id}] Calculating total duration of {len(filtered_files)} files...")
        total_duration = sum(get_video_duration(f) for f in filtered_files)
        if total_duration == 0: raise ValueError("Could not calculate total duration of input files.")
        
        with JOBS_LOCK:
            if job_id not in JOBS: return
            JOBS[job_id]['total_duration'] = total_duration

        output_filepath = os.path.join(TIMELAPSE_OUTPUT_PATH, params['filename'])
        vf_filter = f"setpts={1/speed_factor}*PTS,format=yuv420p"
        
        ffmpeg_cmd = ['ffmpeg', '-y', '-f', 'concat', '-safe', '0', '-i', list_file_path]
        
        if use_nvenc and HWACCEL_TYPE == 'nvidia':
            ffmpeg_cmd.extend(['-vf', vf_filter, '-c:v', 'h264_nvenc', '-preset', 'p5', '-pix_fmt', 'yuv420p'])
        else:
            ffmpeg_cmd.extend(['-threads', '0', '-vf', vf_filter, '-c:v', 'libx264', '-preset', 'fast', '-pix_fmt', 'yuv420p'])
        
        ffmpeg_cmd.extend(['-an', '-r', '30', output_filepath, '-progress', 'pipe:1'])
        
        ffmpeg_cmd_str = shlex.join(ffmpeg_cmd)
        with JOBS_LOCK:
            JOBS[job_id]['debug_info'] = {
                'ffmpeg_command': ffmpeg_cmd_str,
                'file_list': file_list_content
            }

        app.logger.info(f"[{job_id}] Starting ffmpeg process: {ffmpeg_cmd_str}")
        process = subprocess.Popen(ffmpeg_cmd, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, bufsize=1, universal_newlines=True, preexec_fn=os.setsid)
        with JOBS_LOCK:
            if job_id not in JOBS: return
            JOBS[job_id]['pid'] = process.pid
            JOBS[job_id]['status'] = 'running'
        
        for line in iter(process.stdout.readline, ''):
            log_output.append(line)
            parts = line.split('=')
            if len(parts) == 2:
                key, value_str = parts[0].strip(), parts[1].strip()
                with JOBS_LOCK:
                    if job_id not in JOBS or JOBS[job_id]['status'] == 'cancelled': break
                    if key == 'out_time_ms':
                        try:
                            if 'n/a' not in value_str.lower(): JOBS[job_id]['out_time_ms'] = int(value_str)
                        except (ValueError, TypeError):
                            app.logger.warning(f"[{job_id}] Could not parse progress value for out_time_ms: {value_str}")
                    elif key == 'progress' and value_str == 'end': break
        
        return_code = process.wait()
        full_log_str = "".join(log_output)
        
        with JOBS_LOCK:
            if job_id in JOBS:
                JOBS[job_id]['full_log'] = full_log_str
                if return_code == 0:
                    JOBS[job_id]['status'] = 'completed'
                    try:
                        os.makedirs(TIMELAPSE_THUMBNAIL_PATH, exist_ok=True)
                        output_duration = total_duration / speed_factor
                        thumbnail_timestamp = output_duration / 2
                        thumbnail_filepath = os.path.join(TIMELAPSE_THUMBNAIL_PATH, params['thumbnail_filename'])
                        thumb_cmd = ['ffmpeg', '-i', output_filepath, '-ss', str(thumbnail_timestamp), '-vframes', '1', '-filter:v', 'scale=320:-1', thumbnail_filepath]
                        app.logger.info(f"[{job_id}] Generating thumbnail: {shlex.join(thumb_cmd)}")
                        subprocess.run(thumb_cmd, check=True, capture_output=True)
                    except Exception as thumb_e:
                        app.logger.error(f"[{job_id}] Thumbnail generation failed: {thumb_e}")
                else:
                    JOBS[job_id]['status'] = 'failed'

    except Exception as e:
        with JOBS_LOCK:
            if job_id in JOBS:
                JOBS[job_id]['status'] = 'failed'
                JOBS[job_id]['full_log'] = f"Worker thread exception: {e}\\n\\nFFMPEG Command:\\n{ffmpeg_cmd_str}\\n\\nFile List:\\n{file_list_content}"
                app.logger.error(f"FFmpeg worker thread failed for job {job_id}: {e}")
    finally:
        if process and process.pid:
             with JOBS_LOCK:
                 if job_id in JOBS and 'pid' in JOBS[job_id] and JOBS[job_id]['pid']:
                     try: os.killpg(os.getpgid(JOBS[job_id]['pid']), signal.SIGKILL)
                     except ProcessLookupError: pass
        if os.path.exists(list_file_path): os.remove(list_file_path)

@app.route('/')
def index(): return render_template('index.html')
@app.route('/api/data')
def api_data():
    data = get_frigate_data()
    if "error" in data or not data: return jsonify({"error": data.get("error", "Could not find data.")}), 500
    return jsonify(data)
@app.route('/api/hours')
def get_available_hours():
    camera = request.args.get('camera')
    date = request.args.get('date')
    if not camera or not date: return jsonify({"error": "Camera and date parameters are required"}), 400
    date_path = os.path.join(FRIGATE_RECORDINGS_PATH, date)
    if not os.path.isdir(date_path): return jsonify([])
    available_hours = []
    for hour_folder in sorted(os.listdir(date_path)):
        if os.path.isdir(os.path.join(date_path, hour_folder, camera)):
            try: available_hours.append(int(hour_folder))
            except ValueError: continue
    return jsonify(sorted(available_hours))
@app.route('/api/timelapse', methods=['POST'])
def create_timelapse():
    data = request.json
    job_id = uuid.uuid4().hex
    use_nvenc = data.get('use_nvenc', False)
    encoder_tag = "NVIDIA" if use_nvenc and HWACCEL_TYPE == 'nvidia' else "CPU"
    base_filename = f"timelapse-{data['camera']}-{data['date']}_fromhour{int(data['startHour']):02d}tohour{int(data['endHour']):02d}-speed{data['speed']}x_{encoder_tag}"
    output_filename = f"{base_filename}.mp4"
    thumbnail_filename = f"{base_filename}.jpg"
    job_params = {'camera': data['camera'], 'date': data['date'], 'speed': int(data['speed']), 'startHour': int(data['startHour']), 'endHour': int(data['endHour']), 'filename': output_filename, 'thumbnail_filename': thumbnail_filename, 'use_nvenc': use_nvenc}
    with JOBS_LOCK:
        JOBS[job_id] = {'status': 'preparing', 'progress': 0, 'filename': output_filename, 'thumbnail_filename': thumbnail_filename, 'start_time': time.time(), 'params': job_params, 'encoder': encoder_tag, 'id': job_id}
    worker_thread = threading.Thread(target=ffmpeg_worker, args=(job_id, job_params))
    worker_thread.start()
    app.logger.info(f"Submitted job {job_id} for file {output_filename}")
    return jsonify({"message": "Job submitted.", "job_id": job_id}), 202
@app.route('/api/jobs')
def get_all_jobs():
    with JOBS_LOCK:
        current_time = time.time()
        active_jobs = {}
        for job_id, job in JOBS.items():
            if job['status'] in ['running', 'pending', 'preparing', 'failed', 'cancelled']:
                if job['status'] == 'running' and job.get('out_time_ms', 0) > 0 and 'total_duration' in job:
                    time_elapsed = current_time - job['start_time']
                    processed_input_duration = (job.get('out_time_ms', 0) / 1000000) * job['params']['speed']
                    total_input_duration = job.get('total_duration', 1)
                    progress = (processed_input_duration / total_input_duration) * 100
                    job['progress'] = min(100, round(progress, 2))
                    if progress > 1:
                        total_estimated_time = (time_elapsed / progress) * 100
                        eta_seconds = total_estimated_time - time_elapsed
                        job['eta'] = f"{int(eta_seconds // 60)}m {int(eta_seconds % 60)}s" if eta_seconds > 0 else "Finishing..."
                elif job['status'] in ['running', 'pending', 'preparing']:
                    job['eta'] = 'Calculating...'
                active_jobs[job_id] = job
        return jsonify(active_jobs)
@app.route('/api/jobs/clear_failed', methods=['POST'])
def clear_failed_jobs():
    with JOBS_LOCK:
        jobs_to_clear = [job_id for job_id, job in JOBS.items() if job['status'] in ['failed', 'cancelled']]
        for job_id in jobs_to_clear:
            del JOBS[job_id]
    return jsonify({"message": f"Cleared {len(jobs_to_clear)} jobs."})
@app.route('/api/job/<job_id>/cancel', methods=['POST'])
def cancel_job(job_id):
    with JOBS_LOCK:
        job = JOBS.get(job_id)
        if not job or job['status'] not in ['running', 'pending', 'preparing']: return jsonify({"error": "Job not found"}), 404
        job['status'] = 'cancelled'
        if 'pid' in job and job['pid'] is not None:
            try:
                os.killpg(os.getpgid(job['pid']), signal.SIGTERM)
                return jsonify({"message": "Job cancellation requested."})
            except ProcessLookupError: return jsonify({"message": "Job already ended."})
            except OSError as e: return jsonify({"error": f"Failed to cancel job: {e}"}), 500
        return jsonify({"message": "Pending job cancelled."})
@app.route('/api/timelapses')
def list_timelapses():
    completed_jobs = []
    with JOBS_LOCK:
        sorted_jobs = sorted(JOBS.items(), key=lambda item: item[1].get('start_time', 0), reverse=True)
        for job_id, job in sorted_jobs:
            if job['status'] == 'completed':
                video_path = os.path.join(TIMELAPSE_OUTPUT_PATH, job['filename'])
                if os.path.exists(video_path):
                    completed_jobs.append(job)
    return jsonify(completed_jobs)
@app.route('/timelapses/<path:filename>', methods=['DELETE'])
def delete_timelapse(filename):
    if '..' in filename or filename.startswith('/'): return jsonify({"error": "Invalid filename"}), 400
    job_to_delete = None
    with JOBS_LOCK:
        for job_id, job in JOBS.items():
            if job.get('filename') == filename:
                job_to_delete = job
                break
    video_filepath = os.path.join(TIMELAPSE_OUTPUT_PATH, filename)
    if os.path.exists(video_filepath): os.remove(video_filepath)
    else: return jsonify({"error": "File not found"}), 404
    if job_to_delete and 'thumbnail_filename' in job_to_delete:
        thumbnail_filepath = os.path.join(TIMELAPSE_THUMBNAIL_PATH, job_to_delete['thumbnail_filename'])
        if os.path.exists(thumbnail_filepath): os.remove(thumbnail_filepath)
    return jsonify({"message": "File deleted"}), 200
@app.route('/timelapses/<path:filename>')
def serve_timelapse(filename): return send_from_directory(TIMELAPSE_OUTPUT_PATH, filename)
@app.route('/timelapses/thumbnails/<path:filename>')
def serve_thumbnail(filename): return send_from_directory(TIMELAPSE_THUMBNAIL_PATH, filename)

if __name__ == '__main__':
    os.makedirs(TIMELAPSE_THUMBNAIL_PATH, exist_ok=True)
    if os.path.exists(CERT_FILE) and os.path.exists(KEY_FILE):
        app.run(host='0.0.0.0', port=APP_PORT, ssl_context=(CERT_FILE, KEY_FILE))
    else:
        app.run(host='0.0.0.0', port=APP_PORT)
EOF
    success_msg "Created app.py."

    cat <<'EOF' > "${ADDON_DIR}/templates/index.html"
<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>Frigate Timelapse Generator</title>
    <link rel="stylesheet" href="https://cdn.jsdelivr.net/npm/@picocss/pico@1/css/pico.min.css">
    <style>
        :root {
            --pico-font-size: 100%; --pico-background-color: #11191f; --pico-color: #dce3e8;
            --pico-h1-color: #f1f5f9; --pico-h2-color: #f1f5f9;
            --pico-card-background-color: #1e293b; --pico-card-border-color: #334155;
            --pico-form-element-background-color: #334155; --pico-form-element-border-color: #475569;
            --pico-form-element-focus-border-color: #38bdf8;
            --pico-button-background-color: #38a169; --pico-button-border-color: #38a169;
            --pico-button-hover-background-color: #2f855a; --pico-button-hover-border-color: #2f855a;
        }
        body { padding-top: 2rem; padding-bottom: 2rem; }
        main.container { display: grid; grid-template-columns: 1fr 2fr; gap: 2rem; }
        @media (max-width: 992px) { main.container { grid-template-columns: 1fr; } }
        .card { background-color: var(--pico-card-background-color); border: 1px solid var(--pico-card-border-color); padding: 1.5rem; }
        h2 { display: flex; justify-content: space-between; align-items: center; }
        #status-bar { position: fixed; top: 0; left: 0; width: 100%; text-align: center; padding: 0.5rem; z-index: 1000; display: none; color: white; }
        .status-success { background-color: #16a34a; } .status-error { background-color: #dc2626; }
        .timezone-note { font-size: 0.9rem; color: #94a3b8; margin-top: -10px; margin-bottom: 1rem; }
        .hwaccel-container { display: flex; align-items: center; gap: 10px; margin-bottom: 15px; }
        #hwaccel-checkbox { width: auto; margin: 0; }
        label[for="hwaccel-checkbox"] { margin: 0; }
        .job-item, .file-item { display: flex; flex-wrap: wrap; align-items: center; gap: 1rem; background-color: #334155; padding: 1rem; border-radius: var(--pico-border-radius); margin-bottom: 1rem; }
        .item-info { flex-grow: 1; word-break: break-all; }
        .item-actions { display: flex; align-items: center; gap: 0.5rem; flex-wrap: wrap; }
        .progress-container { width: 100%; background-color: #475569; border-radius: 5px; margin-top: 5px; overflow: hidden; height: 0.5rem; }
        .progress-bar { background-color: #38bdf8; height: 100%; width: 0%; transition: width 0.5s ease-in-out; }
        .job-details { font-size: 0.9em; color: #cbd5e1; }
        .job-log, .job-debug-info { display: none; margin-top: 10px; background-color: #11191f; border-radius: 5px; padding: 10px; font-family: monospace; font-size: 0.8em; max-height: 300px; overflow-y: auto; white-space: pre-wrap; word-break: break-all; width: 100%; box-sizing: border-box; }
        .encoder-tag { font-size: 0.75em; padding: 2px 6px; border-radius: 4px; margin-left: 8px; display: inline-block; vertical-align: middle; }
        .encoder-tag-gpu { background-color: #16a34a; color: white; }
        .encoder-tag-cpu { background-color: #3b82f6; color: white; }
        .thumbnail-container { flex-shrink: 0; }
        .thumbnail-container img { width: 160px; height: 90px; border-radius: 4px; background-color: #11191f; object-fit: cover; }
        .file-item .item-info { display: flex; flex-direction: column; justify-content: center; }
        .modal-overlay { position: fixed; top: 0; left: 0; width: 100%; height: 100%; background: rgba(0,0,0,0.7); display: none; justify-content: center; align-items: center; z-index: 2000; }
        .modal-content { background: var(--pico-card-background-color); padding: 2rem; border-radius: var(--pico-border-radius); text-align: left; max-width: 500px; }
        .modal-content h2 { margin-top: 0; }
        button.secondary, button.contrast { --pico-color: white; }
        button.delete-btn, button#clear-failed-btn { background-color: #dc2626; border-color: #dc2626; }
        button.delete-btn:hover, button#clear-failed-btn:hover { background-color: #b91c1c; border-color: #b91c1c; }
    </style>
</head>
<body>
    <div id="status-bar"></div>
    <div id="confirm-modal" class="modal-overlay">
        <div class="modal-content">
            <h2 id="confirm-modal-title">Confirm Action</h2>
            <p id="confirm-modal-text"></p>
            <div class="grid">
                <button id="confirm-modal-no" class="secondary">Cancel</button>
                <button id="confirm-modal-yes">Confirm</button>
            </div>
        </div>
    </div>

    <main class="container">
        <aside>
            <article class="card">
                <h1 style="margin-top:0;">Generator 🎥</h1>
                <div id="controls">
                    <label for="camera-select">Select Camera</label>
                    <select id="camera-select" disabled><option>Loading...</option></select>
                    <label for="date-select">Select Date</label>
                    <select id="date-select" disabled><option>Select camera first</option></select>
                    <div class="timezone-note">Note: Dates and hours reflect the server's timezone (likely UTC).</div>
                    <div class="grid">
                        <div><label for="start-hour">Start Hour</label><select id="start-hour" disabled></select></div>
                        <div><label for="end-hour">End Hour</label><select id="end-hour" disabled></select></div>
                    </div>
                    <label for="speed-input">Timelapse Speed (e.g., 60 for 60x)</label>
                    <input type="number" id="speed-input" value="60" min="2">
                    <div class="hwaccel-container">
                        <input type="checkbox" id="hwaccel-checkbox" role="switch">
                        <label for="hwaccel-checkbox">Use NVIDIA Acceleration (If available)</label>
                    </div>
                    <button id="generate-btn" disabled>Generate Timelapse</button>
                </div>
            </article>
            <article id="active-jobs-section" class="card" style="display: none;">
                <h2>
                    <span>Active Jobs</span>
                    <button id="clear-failed-btn" class="outline secondary" style="display: none; padding: 0.25rem 0.5rem;">Clear Failed</button>
                </h2>
                <ul id="active-jobs-list"></ul>
            </article>
        </aside>
        <section>
            <article class="card">
                <h2>Completed Timelapses</h2>
                <ul id="timelapse-list"><li><progress></progress></li></ul>
                <button id="refresh-list-btn" class="outline secondary">Refresh Lists</button>
            </article>
        </section>
    </main>

    <script>
        const elements = {
            cameraSelect: document.getElementById('camera-select'), dateSelect: document.getElementById('date-select'),
            startHourSelect: document.getElementById('start-hour'), endHourSelect: document.getElementById('end-hour'),
            speedInput: document.getElementById('speed-input'), hwaccelCheckbox: document.getElementById('hwaccel-checkbox'),
            generateBtn: document.getElementById('generate-btn'), statusBar: document.getElementById('status-bar'),
            activeJobsSection: document.getElementById('active-jobs-section'), activeJobsList: document.getElementById('active-jobs-list'),
            clearFailedBtn: document.getElementById('clear-failed-btn'), timelapseList: document.getElementById('timelapse-list'),
            refreshBtn: document.getElementById('refresh-list-btn'), confirmModal: document.getElementById('confirm-modal'),
            confirmModalTitle: document.getElementById('confirm-modal-title'), confirmModalText: document.getElementById('confirm-modal-text'),
            confirmModalYes: document.getElementById('confirm-modal-yes'), confirmModalNo: document.getElementById('confirm-modal-no'),
        };
        let frigateData = {}; let jobMonitorInterval; let viewState = {}; let confirmCallback = null;

        const api = {
            request: async (method, url, payload = null) => {
                try {
                    const options = { method, headers: { 'Content-Type': 'application/json' } };
                    if (payload) options.body = JSON.stringify(payload);
                    const response = await fetch(url, options);
                    const contentType = response.headers.get("content-type");
                    let responseData = (contentType && contentType.includes("application/json")) ? await response.json() : null;
                    if (!response.ok) throw new Error(responseData?.error || `Server error: ${response.status}`);
                    return responseData;
                } catch (error) { console.error(`API request failed: ${method} ${url}`, error); throw error; }
            },
            get: function(url) { return this.request('GET', url); },
            post: function(url, payload) { return this.request('POST', url, payload); },
            delete: function(url) { return this.request('DELETE', url); }
        };
        function showStatus(message, type) {
            elements.statusBar.textContent = message;
            elements.statusBar.className = `status-${type}`;
            elements.statusBar.style.display = 'block';
            setTimeout(() => { elements.statusBar.style.display = 'none'; }, 5000);
        }
        function populateCameras(data) {
            elements.cameraSelect.innerHTML = Object.keys(data).length ? '' : '<option>No cameras found</option>';
            Object.keys(data).forEach(name => elements.cameraSelect.add(new Option(name, name)));
            elements.cameraSelect.disabled = Object.keys(data).length === 0;
            populateDates();
        }
        function populateDates() {
            const selectedCamera = elements.cameraSelect.value;
            const dates = frigateData[selectedCamera] || [];
            elements.dateSelect.innerHTML = dates.length ? '' : '<option>No recordings found</option>';
            dates.forEach(date => elements.dateSelect.add(new Option(date, date)));
            elements.dateSelect.disabled = dates.length === 0;
            updateHourSelectors();
        }
        async function updateHourSelectors() {
            const { cameraSelect, dateSelect, startHourSelect, endHourSelect, generateBtn } = elements;
            const camera = cameraSelect.value, date = dateSelect.value;
            startHourSelect.disabled = true; endHourSelect.disabled = true; generateBtn.disabled = true;
            startHourSelect.innerHTML = ''; endHourSelect.innerHTML = '';
            if (!camera || !date) return;
            try {
                const hours = await api.get(`/api/hours?camera=${encodeURIComponent(camera)}&date=${date}`);
                if (hours.length > 0) {
                    hours.forEach(hour => {
                        const text = hour.toString().padStart(2, '0');
                        startHourSelect.add(new Option(text, hour));
                        endHourSelect.add(new Option(text, hour));
                    });
                    startHourSelect.value = hours[0];
                    endHourSelect.value = hours[hours.length - 1];
                    startHourSelect.disabled = false; endHourSelect.disabled = false; generateBtn.disabled = false;
                }
            } catch (error) { showStatus(`Could not load hours: ${error.message}`, 'error'); }
        }
        function toggleView(jobId, type) {
            const element = document.getElementById(`${type}-${jobId}`);
            if (!element) return;
            const isHidden = element.style.display === 'none';
            element.style.display = isHidden ? 'block' : 'none';
            if (!viewState[jobId]) viewState[jobId] = {};
            viewState[jobId][type] = isHidden;
        }
        function renderJobs(jobs) {
            elements.activeJobsList.innerHTML = '';
            let activeJobCount = 0, hasFailedJobs = false;
            Object.values(jobs).forEach(job => {
                activeJobCount++;
                if (['failed', 'cancelled'].includes(job.status)) hasFailedJobs = true;
                const li = document.createElement('li');
                li.className = 'job-item';
                const jobId = job.id;
                const logDisplay = viewState[jobId]?.log ? 'block' : 'none';
                const debugDisplay = viewState[jobId]?.debug ? 'block' : 'none';
                const logContent = (job.full_log || 'No log output yet...').replace(/</g, "&lt;").replace(/>/g, "&gt;");
                const debugInfo = job.debug_info || {};
                const debugContent = `<strong>FFMPEG Command:</strong>\n${(debugInfo.ffmpeg_command || 'N/A').replace(/</g, "&lt;").replace(/>/g, "&gt;")}\n\n<strong>File List:</strong>\n${(debugInfo.file_list || 'N/A').replace(/</g, "&lt;").replace(/>/g, "&gt;")}`;
                const encoderClass = job.encoder === 'NVIDIA' ? 'encoder-tag-gpu' : 'encoder-tag-cpu';
                const encoderTag = `<span class="encoder-tag ${encoderClass}">${job.encoder}</span>`;
                let buttons = `<button class="outline secondary" onclick="toggleView('${jobId}', 'debug')">Debug</button><button class="outline secondary" onclick="toggleView('${jobId}', 'log')">Log</button>`;
                let content = `<div class="item-info" style="width: 100%;"><strong>${job.filename}</strong>`;
                if (['failed', 'cancelled'].includes(job.status)) {
                    content += `<div class="job-details">Status: <strong style="color: #fca5a5;">${job.status}</strong>${encoderTag}</div></div><div class="item-actions">${buttons}</div>`;
                } else {
                    buttons += `<button class="outline secondary delete-btn" onclick="cancelJob('${jobId}')">Cancel</button>`;
                    content += `<div class="job-details">Status: ${job.status}${encoderTag} | ETA: ${job.eta || 'N/A'}</div>
                                <div class="progress-container"><div class="progress-bar" style="width: ${job.progress || 0}%;"></div></div></div>
                                <div class="item-actions">${buttons}</div>`;
                }
                content += `<pre class="job-debug-info" id="debug-${jobId}" style="display: ${debugDisplay};">${debugContent}</pre>`;
                content += `<pre class="job-log" id="log-${jobId}" style="display: ${logDisplay};">${logContent}</pre>`;
                li.innerHTML = content;
                elements.activeJobsList.appendChild(li);
            });
            elements.activeJobsSection.style.display = activeJobCount > 0 ? 'block' : 'none';
            elements.clearFailedBtn.style.display = hasFailedJobs ? 'inline-block' : 'none';
            return activeJobCount > 0;
        }
        function renderCompleted(jobs) {
            elements.timelapseList.innerHTML = jobs.length === 0 ? '<li>No timelapses generated yet.</li>' : '';
            jobs.forEach(job => {
                const li = document.createElement('li');
                li.className = 'file-item';
                const jobId = job.id;
                const logDisplay = viewState[jobId]?.log ? 'block' : 'none';
                const debugDisplay = viewState[jobId]?.debug ? 'block' : 'none';
                const logContent = (job.full_log || 'No log output.').replace(/</g, "&lt;").replace(/>/g, "&gt;");
                const debugInfo = job.debug_info || {};
                const debugContent = `<strong>FFMPEG Command:</strong>\n${(debugInfo.ffmpeg_command || 'N/A').replace(/</g, "&lt;").replace(/>/g, "&gt;")}\n\n<strong>File List:</strong>\n${(debugInfo.file_list || 'N/A').replace(/</g, "&lt;").replace(/>/g, "&gt;")}`;
                const thumbUrl = `/timelapses/thumbnails/${job.thumbnail_filename}?t=${new Date().getTime()}`;
                li.innerHTML = `
                    <div class="thumbnail-container"><img src="${thumbUrl}" alt="Thumbnail"></div>
                    <div class="item-info"><strong>${job.filename}</strong></div>
                    <div class="item-actions">
                        <a href="/timelapses/${job.filename}" class="contrast" target="_blank">Download</a>
                        <button class="outline secondary" onclick="toggleView('${jobId}', 'debug')">Debug</button>
                        <button class="outline secondary" onclick="toggleView('${jobId}', 'log')">Log</button>
                        <button class="outline secondary delete-btn" onclick="deleteTimelapse('${job.filename}')">Delete</button>
                    </div>
                    <pre class="job-debug-info" id="debug-${jobId}" style="display: ${debugDisplay};">${debugContent}</pre>
                    <pre class="job-log" id="log-${jobId}" style="display: ${logDisplay};">${logContent}</pre>`;
                elements.timelapseList.appendChild(li);
            });
        }
        async function generateTimelapse() {
            const { cameraSelect, dateSelect, speedInput, startHourSelect, endHourSelect, generateBtn, hwaccelCheckbox } = elements;
            const payload = { camera: cameraSelect.value, date: dateSelect.value, speed: speedInput.value, startHour: startHourSelect.value, endHour: endHourSelect.value, use_nvenc: hwaccelCheckbox.checked };
            if (!payload.camera || !payload.date || !payload.startHour) return showStatus('Please select a camera, date, and time range.', 'error');
            generateBtn.disabled = true; generateBtn.setAttribute('aria-busy', 'true');
            try {
                await api.post('/api/timelapse', payload);
                showStatus('Job submitted.', 'success');
                updateJobsStatus();
            } catch (error) { showStatus(`Error: ${error.message}`, 'error');
            } finally { generateBtn.disabled = false; generateBtn.removeAttribute('aria-busy'); }
        }
        async function updateJobsStatus() {
            try {
                const jobs = await api.get('/api/jobs');
                const hasActiveJobs = renderJobs(jobs);
                if (hasActiveJobs && !jobMonitorInterval) jobMonitorInterval = setInterval(updateJobsStatus, 2000);
                else if (!hasActiveJobs && jobMonitorInterval) {
                    clearInterval(jobMonitorInterval);
                    jobMonitorInterval = null;
                    fetchCompletedTimelapses();
                }
            } catch (error) { if(jobMonitorInterval) { clearInterval(jobMonitorInterval); jobMonitorInterval = null; } }
        }
        function showConfirmModal(title, text, callback) {
            elements.confirmModalTitle.textContent = title;
            elements.confirmModalText.textContent = text;
            elements.confirmModal.style.display = 'flex';
            confirmCallback = callback;
        }
        function handleConfirm(confirmed) {
            if (confirmCallback) confirmCallback(confirmed);
            elements.confirmModal.style.display = 'none';
            confirmCallback = null;
        }
        async function cancelJob(jobId) {
            showConfirmModal('Cancel Job?', `Are you sure you want to cancel this job?`, async (confirmed) => {
                if (!confirmed) return;
                try { await api.post(`/api/job/${jobId}/cancel`); showStatus('Cancellation requested.', 'success'); updateJobsStatus();
                } catch (error) { showStatus(`Error: ${error.message}`, 'error'); }
            });
        }
        async function clearFailed() {
             try { await api.post('/api/jobs/clear_failed'); showStatus('Cleared failed/cancelled jobs.', 'success'); updateJobsStatus();
            } catch (error) { showStatus(`Error: ${error.message}`, 'error'); }
        }
        async function fetchCompletedTimelapses() {
            try { renderCompleted(await api.get('/api/timelapses'));
            } catch (error) { elements.timelapseList.innerHTML = '<li>Error loading list.</li>'; }
        }
        async function deleteTimelapse(filename) {
            showConfirmModal('Delete Timelapse?', `Are you sure you want to delete ${filename}?`, async (confirmed) => {
                if (!confirmed) return;
                try { await api.delete(`/timelapses/${filename}`); showStatus(`Deleted ${filename}.`, 'success'); fetchCompletedTimelapses();
                } catch (error) { showStatus(`Error: ${error.message}`, 'error'); }
            });
        }
        async function initializePage() {
            try { frigateData = await api.get('/api/data'); populateCameras(frigateData);
            } catch (error) { showStatus(`Error loading initial data: ${error.message}`, 'error'); }
            fetchCompletedTimelapses();
            updateJobsStatus();
        }
        elements.cameraSelect.addEventListener('change', populateDates);
        elements.dateSelect.addEventListener('change', updateHourSelectors);
        elements.generateBtn.addEventListener('click', generateTimelapse);
        elements.clearFailedBtn.addEventListener('click', clearFailed);
        elements.refreshBtn.addEventListener('click', () => { fetchCompletedTimelapses(); updateJobsStatus(); });
        elements.confirmModalYes.addEventListener('click', () => handleConfirm(true));
        elements.confirmModalNo.addEventListener('click', () => handleConfirm(false));
        initializePage();
    </script>
</body>
</html>
EOF
    success_msg "Created index.html."
}

start_addon() {
    section_header "Starting Frigate Timelapse Addon Installation"
    check_dependencies
    detect_hardware
    find_frigate_paths
    create_addon_files

    section_header "Building Docker Image"
    info_msg "Building '${DOCKER_IMAGE_NAME}' image. This will take a few minutes..."
    docker rmi -f ${DOCKER_IMAGE_NAME} &>/dev/null
    docker build --no-cache -t ${DOCKER_IMAGE_NAME} "${ADDON_DIR}"
    if [ $? -ne 0 ]; then error_msg "Docker image build failed."; exit 1; fi
    success_msg "Docker image built successfully."

    section_header "Starting Timelapse Container"
    info_msg "Stopping and removing any old addon containers..."
    docker stop ${DOCKER_CONTAINER_NAME} &>/dev/null
    docker rm ${DOCKER_CONTAINER_NAME} &>/dev/null

    info_msg "Starting new '${DOCKER_CONTAINER_NAME}' container with HWACCEL_TYPE=${HWACCEL_TYPE}"
    docker run -d \
      --name ${DOCKER_CONTAINER_NAME} \
      --restart=unless-stopped \
      --network=host \
      -e "HWACCEL_TYPE=${HWACCEL_TYPE}" \
      -e "APP_PORT=${ADDON_PORT}" \
      -v "${FRIGATE_CONFIG_PATH}:/config:ro" \
      -v "${FRIGATE_RECORDINGS_PATH_HOST}:/recordings:ro" \
      -v "${ADDON_DIR}/timelapses:/app/timelapses:rw" \
      -v "${ADDON_DIR}/certs:/app/certs:ro" \
      ${DOCKER_HW_FLAGS} \
      ${DOCKER_IMAGE_NAME}
    
    if [ $? -ne 0 ]; then error_msg "Failed to start the timelapse container."; exit 1; fi
    
    sleep 5
    IP_ADDRESS=$(hostname -I | cut -d ' ' -f1)
    success_msg "🎉 Frigate Timelapse Addon is now running!"
    warn_msg "You are using a self-signed certificate, so your browser will show a security warning."
    info_msg "Please accept the warning to proceed."
    info_msg "Access the web interface at: ${COLOR_BOLD}https://${IP_ADDRESS}:${ADDON_PORT}${COLOR_RESET}"
}

delete_addon() {
    section_header "Deleting Frigate Timelapse Addon"
    info_msg "Stopping and removing the timelapse container..."
    docker stop ${DOCKER_CONTAINER_NAME} &>/dev/null
    docker rm ${DOCKER_CONTAINER_NAME} &>/dev/null
    if [ $? -eq 0 ]; then success_msg "Container '${DOCKER_CONTAINER_NAME}' removed."; else warn_msg "Container not found."; fi
    info_msg "Removing the timelapse Docker image..."
    docker rmi ${DOCKER_IMAGE_NAME} &>/dev/null
    if [ $? -eq 0 ]; then success_msg "Image '${DOCKER_IMAGE_NAME}' removed."; else warn_msg "Image not found."; fi
    read -p "${COLOR_PROMPT}Delete addon directory (${ADDON_DIR}) and all generated timelapses? (yes/no): ${COLOR_RESET}" delete_files
    if [[ "$delete_files" == "yes" ]]; then
        rm -rf "${ADDON_DIR}"
        success_msg "Removed addon directory and generated videos."
    else
        info_msg "Addon files and timelapses kept at ${ADDON_DIR}"
    fi
    success_msg "✅ Addon has been successfully uninstalled."
}

main() {
    if [ "$EUID" -ne 0 ]; then
      error_msg "This script needs to be run with sudo or as root to install dependencies."
      exit 1
    fi

    if [ "$1" == "start" ]; then
        start_addon
    elif [ "$1" == "delete" ]; then
        delete_addon
    else
        error_msg "Usage: $0 {start|delete}"
        exit 1
    fi
}

main "$1"

