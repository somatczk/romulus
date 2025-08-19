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
let scaleDownTimeout = null;
let maintenanceInterval = null;

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
    const output = execSync('docker ps --filter "name=github-runner" --format "{{.Names}}"', {
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

// Function to start a single runner instance with unique name
function startSingleRunner() {
  try {
    process.chdir('/workspace');
    
    // Generate unique identifier for this runner
    const timestamp = Date.now();
    const random = Math.random().toString(36).substring(2, 8);
    const runnerSuffix = `${timestamp}-${random}`;
    
    // Set unique container name via environment variable
    const env = {
      ...process.env,
      COMPOSE_PROJECT_NAME: 'romulus',
      RUNNER_SUFFIX: runnerSuffix
    };
    
    // Use docker-compose run to create a new detached runner instance
    // This creates a new container with a unique name each time
    execSync(`docker-compose run -d --name github-runner-${runnerSuffix} github-runner`, {
      stdio: 'pipe',
      timeout: 60000,
      env: env
    });
    
    log('info', `Successfully started runner instance: github-runner-${runnerSuffix}`);
    return true;
  } catch (error) {
    log('error', 'Failed to start runner instance', { error: error.message });
    return false;
  }
}

// Function to ensure minimum runners are running
function ensureMinimumRunners() {
  try {
    const currentCount = getCurrentRunnerCount();
    const needed = config.minRunners - currentCount;
    
    log('info', `Current runners: ${currentCount}, Minimum required: ${config.minRunners}, Need to start: ${Math.max(0, needed)}`);
    
    if (needed > 0) {
      let started = 0;
      for (let i = 0; i < needed; i++) {
        if (startSingleRunner()) {
          started++;
          // Small delay between starts to avoid conflicts
          execSync('sleep 2', { stdio: 'pipe' });
        }
      }
      log('info', `Started ${started} new runners to meet minimum requirement`);
    } else {
      log('debug', 'Minimum runner count already satisfied');
    }
    
    return getCurrentRunnerCount();
  } catch (error) {
    log('error', 'Failed to ensure minimum runners', { error: error.message });
    return getCurrentRunnerCount();
  }
}

// Legacy scaling function for webhook scaling
function scaleUp() {
  const currentCount = getCurrentRunnerCount();
  const newCount = Math.min(config.maxRunners, currentCount + config.scaleUpFactor);
  const needed = newCount - currentCount;
  
  if (needed > 0) {
    log('info', `Scaling up: adding ${needed} runners (${currentCount} -> ${newCount})`);
    for (let i = 0; i < needed; i++) {
      startSingleRunner();
      if (i < needed - 1) {
        execSync('sleep 1', { stdio: 'pipe' });
      }
    }
  }
  
  // Cancel any pending scale down
  if (scaleDownTimeout) {
    clearTimeout(scaleDownTimeout);
    scaleDownTimeout = null;
  }
}



// Health check endpoint
app.get('/health', (req, res) => {
  const currentCount = getCurrentRunnerCount();
  res.json({
    status: 'healthy',
    timestamp: new Date().toISOString(),
    runners: {
      current: currentCount,
      min: config.minRunners,
      max: config.maxRunners
    },
    activeJobs: activeJobs.size
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
        activeJobs.add(jobId);
        log('info', `Job ${jobId} queued, scaling up`, {
          activeJobs: activeJobs.size
        });
        scaleUp();
        break;
        
      case 'in_progress':
        activeJobs.add(jobId);
        log('debug', `Job ${jobId} in progress`, {
          activeJobs: activeJobs.size
        });
        break;
        
      case 'completed':
      case 'cancelled':
        activeJobs.delete(jobId);
        log('info', `Job ${jobId} ${action}`, {
          activeJobs: activeJobs.size
        });
        
        // For ephemeral runners, the runner will self-destruct
        // Periodic maintenance will ensure minimum count is maintained
        break;
        
      default:
        log('debug', `Unhandled action: ${action}`);
    }
    
    res.json({ 
      message: 'Webhook processed successfully',
      action,
      jobId,
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
  res.json({
    config: {
      minRunners: config.minRunners,
      maxRunners: config.maxRunners,
      scaleUpFactor: config.scaleUpFactor,
      scaleDownDelay: config.scaleDownDelay / 1000,
      repository: config.repository
    },
    state: {
      currentRunners: currentCount,
      activeJobs: activeJobs.size,
      jobIds: Array.from(activeJobs),
      hasMaintenanceInterval: maintenanceInterval !== null
    }
  });
});

// Periodic maintenance to ensure minimum runners (every 3 minutes)
function startMaintenanceInterval() {
  maintenanceInterval = setInterval(() => {
    log('info', 'Running periodic maintenance check');
    ensureMinimumRunners();
  }, 3 * 60 * 1000); // 3 minutes in milliseconds
  
  log('info', 'Started periodic maintenance (every 3 minutes)');
}

// Graceful shutdown
process.on('SIGTERM', () => {
  log('info', 'Received SIGTERM, shutting down gracefully');
  
  if (scaleDownTimeout) {
    clearTimeout(scaleDownTimeout);
  }
  
  if (maintenanceInterval) {
    clearInterval(maintenanceInterval);
  }
  
  process.exit(0);
});

process.on('SIGINT', () => {
  log('info', 'Received SIGINT, shutting down gracefully');
  
  if (scaleDownTimeout) {
    clearTimeout(scaleDownTimeout);
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
  
  // Initialize with minimum runners on startup
  log('info', 'Initializing minimum runner count...');
  try {
    ensureMinimumRunners();
    log('info', 'Initial runner setup completed');
  } catch (error) {
    log('error', 'Failed to initialize runners', { error: error.message });
  }
  
  // Start periodic maintenance
  startMaintenanceInterval();
});
