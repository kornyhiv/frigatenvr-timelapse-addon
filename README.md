# frigatenvr-timelapse-addon

A standalone, self-contained script that deploys a web-based tool to create timelapses from your Frigate NVR recordings.

The script provides a simple web UI to select a camera, date, and time range, and then uses FFmpeg to generate a high-speed timelapse video. It automatically detects hardware acceleration (NVIDIA/Intel QSV) to speed up the process.


<img width="1166" height="881" alt="image" src="https://github.com/user-attachments/assets/a9595b55-f5d3-4755-af07-2e0111978a11" />


Features

•	Simple Web Interface: Easily select the camera, date, and hour range for your timelapse.

•	Adjustable Speed: Choose how much to speed up the final video (e.g., 60x, 120x).

•	Hardware Acceleration: Automatically detects and utilizes NVIDIA (NVENC) or Intel (QSV) GPUs for faster video encoding.

(User can select CPU only or hardware acceleration manually)

•	Job Queue: See the progress of active jobs, view logs, and manage completed files.

•	Easy Installation: Deployed via a single bash script that creates and manages the required Docker container.


Prerequisites

This script is designed for Debian-based systems (like Ubuntu, Debian) and requires the following to be installed:

•	Docker: To run the addon container.

•	jq, yq, lspci, wget: Command-line tools for setup and hardware detection.

The addon automatically uses the "frigate" docker container if using the easy installation script. No additional configuration is needed.


The script will attempt to automatically install these dependencies if they are not found.


Installation

1.	Download the frigate_timelapse.sh script to your Frigate server.
2.	Make the script executable:
3.	chmod +x frigate_timelapse.sh
4.	Run the installer with sudo. It needs root permissions to interact with Docker and install dependencies.
5.	sudo ./frigate_timelapse.sh start


The script will build the Docker image and launch the container.


Note on SSL Certificate: The script generates a self-signed SSL certificate for HTTPS. When you first access the web UI, your browser will show a security warning. This is expected. Please proceed past the warning to access the application.


Usage


Once installed, you can access the web UI at https://<YOUR_SERVER_IP>:5005.
You can also manage the addon from your terminal:
•	Stop and Delete the addon (removes container, image, and all files):
•	sudo ./frigate_timelapse.sh delete


Screenshots:

<img width="1133" height="900" alt="image" src="https://github.com/user-attachments/assets/b1f920e2-3f15-4e35-a77a-f86d6b4137ca" />


<img width="1154" height="902" alt="image" src="https://github.com/user-attachments/assets/f755d566-bedb-40ce-a140-e05c0d21a230" />




Disclaimer & About

This is a community-developed project and is not officially supported by the Frigate team. It was created as a proof-of-concept to explore what was possible.
This project is provided "as is" and without any warranty. The author is not responsible for any damage or loss caused by its use. You are using this software at your own risk.
This script was developed in collaboration with a large language model (Google's Gemini). The entire process, from initial code generation to debugging and refinement, was guided and validated by Google Gemini, and end users.

**This is a community-developed project and is not officially supported by the Frigate team.** 

