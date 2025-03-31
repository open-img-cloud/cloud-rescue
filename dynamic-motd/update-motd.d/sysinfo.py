#!/usr/bin/python3
"""
landscape-sysinfo-mini.py -- a trivial re-implementation of the
sysinfo printout shown at boot time. No twisted, no reactor, just /proc

Original (C) 2014 jw@owncloud.com
Modified by Luc Didry in 2016 and 2023
Further adapted for Rocky Linux - utmp dependency removed and replaced with subprocess

Get the original version at https://github.com/jnweiger/landscape-sysinfo-mini
"""

import sys
import os
import time
import glob
import subprocess

VERSION = '1.4'

def count_users():
    """ Count user processes using the 'who' command
    """
    try:
        result = subprocess.run(['who'], capture_output=True, text=True, check=False)
        if result.returncode == 0:
            # Count unique users by creating a set of usernames
            users = set()
            for line in result.stdout.splitlines():
                if line.strip():
                    parts = line.split()
                    if parts:
                        users.add(parts[0])
            return len(users)
        return 0
    except Exception as e:
        print(f"Erreur lors du comptage des utilisateurs: {e}")
        return 0

def get_logged_users():
    """ Get details of logged in users using the 'who' command
    """
    users = []
    try:
        result = subprocess.run(['who', '-u'], capture_output=True, text=True, check=False)
        if result.returncode == 0:
            for line in result.stdout.splitlines():
                if line.strip():
                    parts = line.split()
                    if len(parts) >= 5:
                        user = {
                            'username': parts[0],
                            'host': parts[len(parts)-1] if '(' in parts[len(parts)-1] else '',
                            'time': ' '.join(parts[2:5]) if len(parts) >= 5 else ''
                        }
                        users.append(user)
    except Exception as e:
        print(f"Erreur lors de la récupération des utilisateurs: {e}")
    return users

def proc_meminfo():
    """ Get memory usage informations
    """
    items = {}
    try:
        for line in open('/proc/meminfo', encoding="ASCII").readlines():
            array = line.split()
            if len(array) >= 2:
                items[array[0]] = int(array[1])
    except Exception as e:
        print(f"Erreur lors de la lecture de /proc/meminfo: {e}")
    return items

def proc_mount():
    """ Get disks space usage
    """
    items = {}
    try:
        for mount in open('/proc/mounts', encoding="ASCII").readlines():
            array = mount.split()
            if len(array) >= 2 and array[0].find('/dev/') == 0:
                try:
                    l_statfs = os.statvfs(array[1])
                    if l_statfs.f_blocks != 0:
                        perc = 100 - 100. * l_statfs.f_bavail / l_statfs.f_blocks
                    else:
                        perc = 100
                    g_b = l_statfs.f_bsize * l_statfs.f_blocks / 1024. / 1024 / 1024
                    items[array[1]] = f"{perc:5.1f}% of {g_b:.2f}GB"
                except Exception:
                    pass
    except Exception as e:
        print(f"Erreur lors de la lecture de /proc/mounts: {e}")
    return items

def inode_proc_mount():
    """ Get disks inode usage
    """
    items = {}
    try:
        for mount in open('/proc/mounts', encoding="ASCII").readlines():
            array = mount.split()
            if len(array) >= 2 and array[0].find('/dev/') == 0:
                try:
                    l_statfs = os.statvfs(array[1])
                    if l_statfs.f_files != 0:
                        perc = 100 - 100. * l_statfs.f_ffree / l_statfs.f_files
                    else:
                        perc = 100
                    i_total = l_statfs.f_files
                    items[array[1]] = f"{perc:5.1f}% of {i_total}"
                except Exception:
                    pass
    except Exception as e:
        print(f"Erreur lors de la lecture des inodes: {e}")
    return items

# Main program
try:
    with open("/proc/loadavg", encoding="ASCII") as avg_line:
        loadav = float(avg_line.read().split()[1])
except Exception:
    loadav = 0.0

processes = len(glob.glob('/proc/[0-9]*'))
statfs = proc_mount()
i_statfs = inode_proc_mount()
USERS = count_users()
meminfo = proc_meminfo()

# Calculate memory percentage - handling different key names depending on kernel version
if 'MemAvailable:' in meminfo and 'MemTotal:' in meminfo and meminfo['MemTotal:'] > 0:
    memperc = f"{100 - 100. * meminfo.get('MemAvailable:', 0) / meminfo['MemTotal:']:.2f}%"
else:
    # Fallback if MemAvailable is not available (older kernels)
    mem_free = meminfo.get('MemFree:', 0) + meminfo.get('Buffers:', 0) + meminfo.get('Cached:', 0)
    if 'MemTotal:' in meminfo and meminfo['MemTotal:'] > 0:
        memperc = f"{100 - 100. * mem_free / meminfo['MemTotal:']:.2f}%"
    else:
        memperc = "N/A"

# Calculate swap percentage
if 'SwapTotal:' in meminfo and meminfo['SwapTotal:'] > 0:
    SWAPPERC = f"{100 - 100. * meminfo.get('SwapFree:', 0) / meminfo['SwapTotal:']:.2f}%"
else:
    SWAPPERC = '---'

print(f"  System information as of {time.asctime()}\n")
print(f"  System load:  {loadav: <5.2f}                Processes:           {processes}")
print(f"  Memory usage: {memperc: <4}               Users logged in:     {USERS}")
print(f"  Swap usage:   {SWAPPERC}")

print("  Disk Usage:")
for k in sorted(statfs.keys()):
    print(f"    Usage of {k: <24}: {statfs[k]: <20}")

print("  Inode Usage:")
for l in sorted(i_statfs.keys()):
    print(f"    Usage of {l: <24}: {i_statfs[l]: <20}")

# Display logged in users if any
if USERS > 0:
    print("\n  Logged in users:")
    for user in get_logged_users():
        username = user['username']
        host = user['host'].strip('()')
        time_str = user['time']
        print(f"  \033[1;31m{username: <10}\033[m from {host: <25} at {time_str: <20}")

sys.exit(0)
