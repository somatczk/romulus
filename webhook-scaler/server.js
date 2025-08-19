const express = require('express');
const crypto = require('crypto');
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
let currentRunners = config.minRunners;
let activeJobs = new Set();
let scaleDownTimeout = null;

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

// Docker Compose scaling functions
function scaleRunners(count) {
  try {
    const clampedCount = Math.max(config.minRunners, Math.min(config.maxRunners, count));
    
    if (clampedCount === currentRunners) {
      log('debug', `Runners already at target count: ${clampedCount}`);
      return;
    }

    log('info', `Scaling runners from ${currentRunners} to ${clampedCount}`);
    
    // Change to project directory and scale
    process.chdir('/workspace');
    execSync(`docker-compose up --scale github-runner=${clampedCount} -d`, {
      stdio: 'pipe',
      timeout: 60000
    });
    
    currentRunners = clampedCount;
    log('info', `Successfully scaled to ${clampedCount} runners`);
    
  } catch (error) {
    log('error', 'Failed to scale runners', { 
      error: error.message,
      targetCount: count 
    });
    throw error;
  }
}

function scaleUp() {
  const newCount = Math.min(config.maxRunners, currentRunners + config.scaleUpFactor);
  scaleRunners(newCount);
  
  // Cancel any pending scale down
  if (scaleDownTimeout) {
    clearTimeout(scaleDownTimeout);
    scaleDownTimeout = null;
  }
}

function scheduleScaleDown() {
  // Cancel existing timeout
  if (scaleDownTimeout) {
    clearTimeout(scaleDownTimeout);
  }
  
  // Only schedule scale down if we have active jobs being tracked
  if (activeJobs.size === 0) {
    scaleDownTimeout = setTimeout(() => {
      log('info', 'No active jobs detected, scaling down');
      scaleRunners(config.minRunners);
      scaleDownTimeout = null;
    }, config.scaleDownDelay);
    
    log('debug', `Scheduled scale down in ${config.scaleDownDelay / 1000} seconds`);
  }
}

// Health check endpoint
app.get('/health', (req, res) => {
  res.json({
    status: 'healthy',
    timestamp: new Date().toISOString(),
    runners: {
      current: currentRunners,
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
        
        // Schedule scale down if no active jobs
        if (activeJobs.size === 0) {
          scheduleScaleDown();
        }
        break;
        
      default:
        log('debug', `Unhandled action: ${action}`);
    }
    
    res.json({ 
      message: 'Webhook processed successfully',
      action,
      jobId,
      activeJobs: activeJobs.size,
      currentRunners
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
  res.json({
    config: {
      minRunners: config.minRunners,
      maxRunners: config.maxRunners,
      scaleUpFactor: config.scaleUpFactor,
      scaleDownDelay: config.scaleDownDelay / 1000,
      repository: config.repository
    },
    state: {
      currentRunners,
      activeJobs: activeJobs.size,
      jobIds: Array.from(activeJobs),
      hasScaleDownScheduled: scaleDownTimeout !== null
    }
  });
});

// Graceful shutdown
process.on('SIGTERM', () => {
  log('info', 'Received SIGTERM, shutting down gracefully');
  
  if (scaleDownTimeout) {
    clearTimeout(scaleDownTimeout);
  }
  
  process.exit(0);
});

process.on('SIGINT', () => {
  log('info', 'Received SIGINT, shutting down gracefully');
  
  if (scaleDownTimeout) {
    clearTimeout(scaleDownTimeout);
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
  
  // Initialize with minimum runners
  try {
    scaleRunners(config.minRunners);
  } catch (error) {
    log('error', 'Failed to initialize runners', { error: error.message });
  }
});