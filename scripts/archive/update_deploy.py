import re
import os

files = [
    "stacks/auth/docker-compose.yml",
    "stacks/gateway/docker-compose.yml",
    "stacks/media/ai-interface/docker-compose.yml",
    "stacks/observability/docker-compose.yml",
    "stacks/management/docker-compose.yml",
    "stacks/network/docker-compose.yml",
    "stacks/uptime/docker-compose.yml",
    "stacks/cloud/docker-compose.yml"
]

modified_files = []

for file_path in files:
    with open(file_path, "r") as f:
        lines = f.readlines()
        
    out = []
    i = 0
    modified = False
    while i < len(lines):
        line = lines[i]
        out.append(line)
        if line.lstrip().startswith("deploy:") and not line.lstrip().startswith("#"):
            indent = len(line) - len(line.lstrip())
            child_indent = " " * (indent + 2)
            child_child_indent = " " * (indent + 4)
            
            # Find the end of deploy block
            j = i + 1
            deploy_block = []
            while j < len(lines):
                if lines[j].strip() == "":
                    deploy_block.append(lines[j])
                    j += 1
                    continue
                curr_indent = len(lines[j]) - len(lines[j].lstrip())
                if curr_indent <= indent and not lines[j].lstrip().startswith("#"):
                    break
                deploy_block.append(lines[j])
                j += 1
                
            # Parse deploy block lines
            update_config_found = False
            has_start_first = False
            
            for k, dline in enumerate(deploy_block):
                if dline.lstrip().startswith("update_config:"):
                    update_config_found = True
                    # check next lines for order: start-first
                    m = k + 1
                    while m < len(deploy_block):
                        m_line = deploy_block[m]
                        if m_line.strip() == "":
                            m += 1
                            continue
                        m_indent = len(m_line) - len(m_line.lstrip())
                        if m_indent <= len(dline) - len(dline.lstrip()):
                            break
                        if "order:" in m_line and "start-first" in m_line:
                            has_start_first = True
                        m += 1
                    break
            
            if not update_config_found:
                out.append(f"{child_indent}update_config:\n{child_child_indent}parallelism: 1\n{child_child_indent}delay: 10s\n{child_child_indent}order: start-first\n")
                modified = True
                
                # Append the rest of deploy block
                for dline in deploy_block:
                    out.append(dline)
                i = j
                continue
            elif not has_start_first:
                # Remove old update_config block
                new_deploy_block = []
                skip = False
                for dline in deploy_block:
                    if dline.lstrip().startswith("update_config:"):
                        skip = True
                        continue
                    if skip:
                        if dline.strip() == "":
                            continue
                        m_indent = len(dline) - len(dline.lstrip())
                        if m_indent <= indent + 2:
                            skip = False
                        else:
                            continue
                    
                    if not skip:
                        new_deploy_block.append(dline)
                
                # Add new update_config
                out.append(f"{child_indent}update_config:\n{child_child_indent}parallelism: 1\n{child_child_indent}delay: 10s\n{child_child_indent}order: start-first\n")
                for dline in new_deploy_block:
                    out.append(dline)
                    
                modified = True
                i = j
                continue
            else:
                # everything is perfect, just append them
                for dline in deploy_block:
                    out.append(dline)
                i = j
                continue
        i += 1
        
    if modified:
        with open(file_path, "w") as f:
            f.writelines(out)
        modified_files.append(file_path)

print("MODIFIED FILES:")
for f in modified_files:
    print(f)

