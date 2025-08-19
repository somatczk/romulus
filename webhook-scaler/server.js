const express = require('express');
const crypto = require('node:crypto');
const { execSync } = require('child_process');

const app = express();
const PORT = process.env.PORT || 3000;

// Configuration from environment variables
const config = {
  webhookSecret: process.env.GITHUB_WEBHOOK_SECRET,
  minRunners: parseInt(process.env.MIN_RUNNERS || '1'),
  maxRunners: parseInt(process.env.MAX_RUNNERS || '5'),
  scaleUpFactor: parseInt(process.env.SCALE_UP_FACTOR || '1'),
  scaleDownDelay: parseInt(process.env.SCALE_DOWN_DELAY || '300') * 1000, // Convert to ms
  logLevel: process.env.LOG_LEVEL || 'info',
  repository: process.env.GITHUB_REPOSITORY
};

// State tracking
let activeJobs = new Set();
let queuedJobs = new Set();
let maintenanceInterval = null;
let lastScaleAction = 0;
let pendingScaleDown = null;

// Middleware
app.use(express.json());

// Logging helper
function log(level, message, data = {}) {
  const levels = ['error', 'warn', 'info', 'debug'];
  const configLevel = levels.indexOf(config.logLevel);
  const messageLevel = levels.indexOf(level);
  
  if (messageLevel <= configLevel) {
    console.log(JSON.stringify({
      timestamp: new Date().toISOString(),
      level,
      message,
      ...data
    }));
  }
}

// Webhook signature verification
function verifySignature(payload, signature) {
  if (!config.webhookSecret) {
    log('warn', 'No webhook secret configured, skipping verification');
    return true;
  }

  const expectedSignature = 'sha256=' + crypto
    .createHmac('sha256', config.webhookSecret)
    .update(payload)
    .digest('hex');

  return crypto.timingSafeEqual(
    Buffer.from(signature),
    Buffer.from(expectedSignature)
  );
}

// Helper function to get current runner count
function getCurrentRunnerCount() {
  try {
    const output = execSync('docker ps --filter "label=com.github.runner.scaler=worker" --format "{{.Names}}"', {
      stdio: 'pipe',
      timeout: 10000,
      encoding: 'utf8'
    });
    const runnerNames = output.trim().split('\n').filter(name => name.length > 0);
    return runnerNames.length;
  } catch (error) {
    log('error', 'Failed to get current runner count', { error: error.message });
    return 0;
  }
}

// Helper function to create a new runner container
function createRunnerContainer() {
  try {
    const timestamp = Date.now();
    const containerName = `romulus_github-runner_${timestamp}`;
    
    const dockerCmd = [
      'docker run -d',
      `--name ${containerName}`,
      '--restart unless-stopped',
      '--network romulus_frontend',
      '--label "com.github.runner.scaler=worker"',
      '--label "com.docker.compose.project=romulus"',
      '--label "com.docker.compose.service=github-runner"',
      `-e RUNNER_WORKDIR=/tmp/runner/work`,
      `-e RUNNER_GROUP=${process.env.RUNNER_GROUP || 'default'}`,
      `-e RUNNER_SCOPE=repo`,
      `-e LABELS=self-hosted,Linux,X64,homeserver,docker`,
      `-e REPO_URL=https://github.com/${config.repository}`,
      `-e ACCESS_TOKEN=${process.env.GITHUB_RUNNER_TOKEN}`,
      `-e RUNNER_REPLACE_EXISTING=false`,
      `-e DISABLE_RUNNER_UPDATE=false`,
      `-e EPHEMERAL=true`,
      `-e DOCKER_HOST=unix:///var/run/docker.sock`,
      `-e START_DOCKER_SERVICE=false`,
      `-e RUN_AS_ROOT=true`,
      `-e TZ=${process.env.TZ || 'UTC'}`,
      `-v ${process.env.SSD_PATH || '/tmp'}/runner/work:/tmp/runner/work`,
      `-v /var/run/docker.sock:/var/run/docker.sock:rw`
    ];
    
    // Skip PROJECT_PATH mount entirely for autoscaled containers
    // Ephemeral runners will checkout their own workspace via GitHub Actions
    const projectPath = process.env.PROJECT_PATH;
    log('info', `Skipping PROJECT_PATH mount for autoscaled runner`, { 
      projectPath: projectPath,
      reason: 'Ephemeral runners manage their own workspace - no host mounts needed'
    });
    
    dockerCmd.push(
      `--memory=${process.env.RUNNER_MEMORY_LIMIT || '4g'}`,
      `--cpus=${process.env.RUNNER_CPU_LIMIT || '4.0'}`,
      '--security-opt no-new-privileges:true',
      'myoung34/github-runner:latest'
    );
    
    const dockerCmdString = dockerCmd.join(' ');
    
    execSync(dockerCmdString, {
      stdio: 'pipe',
      timeout: 30000,
      encoding: 'utf8',
      cwd: '/app'
    });
    
    log('info', `Created new runner container: ${containerName}`);
    return containerName;
  } catch (error) {
    log('error', 'Failed to create runner container', { error: error.message });
    return null;
  }
}

// Helper function to remove excess runner containers
function removeExcessRunners(targetCount) {
  try {
    const output = execSync('docker ps --filter "label=com.github.runner.scaler=worker" --format "{{.Names}} {{.CreatedAt}}"', {
      stdio: 'pipe',
      timeout: 10000,
      encoding: 'utf8'
    });
    
    const containers = output.trim().split('\n')
      .filter(line => line.length > 0)
      .map(line => {
        const parts = line.split(' ');
        return {
          name: parts[0],
          created: new Date(parts.slice(1).join(' '))
        };
      })
      .sort((a, b) => b.created - a.created); // Sort by creation time, newest first
    
    const currentCount = containers.length;
    if (currentCount <= targetCount) {
      return; // Nothing to remove
    }
    
    const containersToRemove = containers.slice(targetCount); // Remove oldest containers
    
    for (const container of containersToRemove) {
      try {
        execSync(`docker stop ${container.name}`, {
          stdio: 'pipe',
          timeout: 15000
        });
        execSync(`docker rm ${container.name}`, {
          stdio: 'pipe',
          timeout: 10000
        });
        log('info', `Removed excess runner container: ${container.name}`);
      } catch (error) {
        log('error', `Failed to remove container ${container.name}`, { error: error.message });
      }
    }
  } catch (error) {
    log('error', 'Failed to remove excess runners', { error: error.message });
  }
}

// Function to scale runners to a specific count
function scaleRunners(targetCount) {
  const currentCount = getCurrentRunnerCount();
  
  if (currentCount === targetCount) {
    log('debug', 'Already at target runner count', { current: currentCount, target: targetCount });
    return true;
  }
  
  log('info', 'Scaling runners', { current: currentCount, target: targetCount });
  
  if (currentCount < targetCount) {
    // Scale up: create new containers
    const containersToCreate = targetCount - currentCount;
    let successCount = 0;
    
    for (let i = 0; i < containersToCreate; i++) {
      if (createRunnerContainer()) {
        successCount++;
      }
    }
    
    log('info', `Scale up completed: created ${successCount}/${containersToCreate} containers`);
    return successCount === containersToCreate;
  } else {
    // Scale down: remove excess containers
    removeExcessRunners(targetCount);
    
    // Verify the scaling
    setTimeout(() => {
      const finalCount = getCurrentRunnerCount();
      log('info', `Scale down completed: final count ${finalCount}, target ${targetCount}`);
    }, 2000);
    
    return true;
  }
}

// Function to calculate optimal runner count based on queue and active jobs
function calculateOptimalRunnerCount() {
  const currentCount = getCurrentRunnerCount();
  const queuedCount = queuedJobs.size;
  const activeCount = activeJobs.size;
  
  // Always ensure minimum runners
  let targetCount = Math.max(config.minRunners, currentCount);
  
  // Scale up logic: ensure we have enough runners for queued jobs
  if (queuedCount > 0) {
    // We want at least as many runners as queued jobs, plus some buffer for currently active jobs
    const neededRunners = Math.min(queuedCount + activeCount, config.maxRunners);
    targetCount = Math.max(targetCount, neededRunners);
    
    log('info', 'Scaling up for queued jobs', {
      queued: queuedCount,
      active: activeCount,
      current: currentCount,
      target: targetCount
    });
  } else if (activeCount === 0 && currentCount > config.minRunners) {
    // Scale down logic: if no jobs are running and we have more than minimum runners
    // Only scale down after a delay to avoid thrashing
    targetCount = config.minRunners;
    
    log('info', 'Preparing to scale down - no active jobs', {
      current: currentCount,
      target: targetCount,
      minRunners: config.minRunners
    });
  }
  
  return Math.min(Math.max(targetCount, config.minRunners), config.maxRunners);
}

// Function to ensure optimal number of runners
function ensureOptimalRunners(immediate = false) {
  const currentCount = getCurrentRunnerCount();
  const targetCount = calculateOptimalRunnerCount();
  
  log('info', 'Runner scaling check', {
    current: currentCount,
    target: targetCount,
    queued: queuedJobs.size,
    active: activeJobs.size,
    immediate
  });
  
  // Prevent too frequent scaling actions
  const now = Date.now();
  const timeSinceLastScale = now - lastScaleAction;
  const minScaleInterval = 10000; // 10 seconds minimum between scaling actions
  
  if (!immediate && timeSinceLastScale < minScaleInterval) {
    log('debug', 'Skipping scaling - too soon after last action', {
      timeSinceLastScale: Math.round(timeSinceLastScale / 1000),
      minInterval: Math.round(minScaleInterval / 1000)
    });
    return currentCount;
  }
  
  if (targetCount !== currentCount) {
    if (targetCount > currentCount) {
      // Scale up immediately when jobs are queued
      if (scaleRunners(targetCount)) {
        lastScaleAction = now;
        // Clear any pending scale down
        if (pendingScaleDown) {
          clearTimeout(pendingScaleDown);
          pendingScaleDown = null;
        }
      }
    } else if (targetCount < currentCount) {
      // Scale down with delay to avoid thrashing
      if (pendingScaleDown) {
        clearTimeout(pendingScaleDown);
      }
      
      log('info', `Scheduling scale down in ${config.scaleDownDelay / 1000} seconds`);
      pendingScaleDown = setTimeout(() => {
        const recalculatedTarget = calculateOptimalRunnerCount();
        const currentAtDelay = getCurrentRunnerCount();
        
        // Double-check that we still want to scale down
        if (recalculatedTarget < currentAtDelay && queuedJobs.size === 0 && activeJobs.size === 0) {
          if (scaleRunners(recalculatedTarget)) {
            lastScaleAction = Date.now();
          }
        } else {
          log('info', 'Scale down cancelled - jobs appeared during delay');
        }
        pendingScaleDown = null;
      }, config.scaleDownDelay);
    }
    
    // Wait a moment for containers to start, then check final count
    setTimeout(() => {
      const finalCount = getCurrentRunnerCount();
      log('info', `Scaling check completed. Final runner count: ${finalCount}`);
    }, 5000);
  } else {
    log('debug', 'No scaling needed - already at optimal count');
  }
  
  return currentCount;
}



// Health check endpoint
app.get('/health', (req, res) => {
  const currentCount = getCurrentRunnerCount();
  res.json({
    status: 'healthy',
    timestamp: new Date().toISOString(),
    runners: {
      current: currentCount,
      optimal: calculateOptimalRunnerCount(),
      min: config.minRunners,
      max: config.maxRunners
    },
    jobs: {
      queued: queuedJobs.size,
      active: activeJobs.size,
      total: queuedJobs.size + activeJobs.size
    }
  });
});

// Webhook endpoint
app.post('/webhook', (req, res) => {
  const signature = req.get('X-Hub-Signature-256');
  const payload = JSON.stringify(req.body);
  
  // Verify webhook signature
  if (!verifySignature(payload, signature)) {
    log('warn', 'Invalid webhook signature');
    return res.status(401).json({ error: 'Invalid signature' });
  }
  
  const event = req.body;
  const eventType = req.get('X-GitHub-Event');
  
  log('debug', 'Received webhook', {
    event: eventType,
    action: event.action,
    repository: event.repository?.full_name
  });
  
  // Only process workflow_job events for our repository
  if (eventType !== 'workflow_job') {
    log('debug', 'Ignoring non-workflow_job event', { eventType });
    return res.json({ message: 'Event ignored' });
  }
  
  if (config.repository && event.repository?.full_name !== config.repository) {
    log('debug', 'Ignoring event from different repository', {
      received: event.repository?.full_name,
      expected: config.repository
    });
    return res.json({ message: 'Repository mismatch' });
  }
  
  const job = event.workflow_job;
  const jobId = job.id;
  const action = event.action;
  
  // Check if job targets self-hosted runners
  const labels = job.labels || [];
  const isSelfHosted = labels.includes('self-hosted');
  
  if (!isSelfHosted) {
    log('debug', 'Job does not target self-hosted runners', { jobId, labels });
    return res.json({ message: 'Not a self-hosted job' });
  }
  
  log('info', 'Processing workflow job event', {
    action,
    jobId,
    jobName: job.name,
    labels
  });
  
  try {
    switch (action) {
      case 'queued':
        queuedJobs.add(jobId);
        log('info', `Job ${jobId} queued`, {
          queuedJobs: queuedJobs.size,
          activeJobs: activeJobs.size
        });
        
        // Trigger immediate scale-up for queued jobs
        ensureOptimalRunners(true);
        break;
        
      case 'in_progress':
        // Move from queued to active
        queuedJobs.delete(jobId);
        activeJobs.add(jobId);
        log('info', `Job ${jobId} started`, {
          queuedJobs: queuedJobs.size,
          activeJobs: activeJobs.size
        });
        break;
        
      case 'completed':
      case 'cancelled':
        // Remove from both sets (job could be in either)
        queuedJobs.delete(jobId);
        activeJobs.delete(jobId);
        log('info', `Job ${jobId} ${action}`, {
          queuedJobs: queuedJobs.size,
          activeJobs: activeJobs.size
        });
        
        // Check if we can scale down
        ensureOptimalRunners();
        break;
        
      default:
        log('debug', `Unhandled action: ${action}`);
    }
    
    res.json({ 
      message: 'Webhook processed successfully',
      action,
      jobId,
      queuedJobs: queuedJobs.size,
      activeJobs: activeJobs.size,
      currentRunners: getCurrentRunnerCount()
    });
    
  } catch (error) {
    log('error', 'Error processing webhook', {
      error: error.message,
      action,
      jobId
    });
    res.status(500).json({ error: 'Internal server error' });
  }
});

// Stats endpoint
app.get('/stats', (req, res) => {
  const currentCount = getCurrentRunnerCount();
  const optimalCount = calculateOptimalRunnerCount();
  
  res.json({
    config: {
      minRunners: config.minRunners,
      maxRunners: config.maxRunners,
      scaleUpFactor: config.scaleUpFactor,
      scaleDownDelay: config.scaleDownDelay / 1000,
      repository: config.repository
    },
    runners: {
      current: currentCount,
      optimal: optimalCount,
      scalingNeeded: currentCount !== optimalCount
    },
    jobs: {
      queued: {
        count: queuedJobs.size,
        ids: Array.from(queuedJobs)
      },
      active: {
        count: activeJobs.size,
        ids: Array.from(activeJobs)
      }
    },
    state: {
      lastScaleAction: new Date(lastScaleAction).toISOString(),
      hasPendingScaleDown: pendingScaleDown !== null,
      hasMaintenanceInterval: maintenanceInterval !== null
    }
  });
});

// Periodic maintenance to ensure optimal runners (every 2 minutes)
function startMaintenanceInterval() {
  maintenanceInterval = setInterval(() => {
    log('info', 'Running periodic maintenance check');
    
    // Note: In a production environment, you might want to implement
    // stale job cleanup based on timestamps. For now, we rely on webhook events.
    
    ensureOptimalRunners();
  }, 120 * 1000); // Every 2 minutes
  
  log('info', 'Started periodic maintenance (every 2 minutes)');
}

// Graceful shutdown
process.on('SIGTERM', () => {
  log('info', 'Received SIGTERM, shutting down gracefully');
  
  if (pendingScaleDown) {
    clearTimeout(pendingScaleDown);
  }
  
  if (maintenanceInterval) {
    clearInterval(maintenanceInterval);
  }
  
  process.exit(0);
});

process.on('SIGINT', () => {
  log('info', 'Received SIGINT, shutting down gracefully');
  
  if (pendingScaleDown) {
    clearTimeout(pendingScaleDown);
  }
  
  if (maintenanceInterval) {
    clearInterval(maintenanceInterval);
  }
  
  process.exit(0);
});

// Start server
app.listen(PORT, () => {
  log('info', 'GitHub Runner Webhook Scaler started', {
    port: PORT,
    config: {
      minRunners: config.minRunners,
      maxRunners: config.maxRunners,
      scaleUpFactor: config.scaleUpFactor,
      scaleDownDelaySeconds: config.scaleDownDelay / 1000,
      repository: config.repository
    }
  });
  
  // Ensure optimal runners on startup
  log('info', 'Ensuring optimal runners on startup...');
  try {
    ensureOptimalRunners(true);
    log('info', 'Initial scaling check completed');
  } catch (error) {
    log('error', 'Failed to ensure optimal runners on startup', { error: error.message });
  }
  
  // Start periodic maintenance
  startMaintenanceInterval();
});
