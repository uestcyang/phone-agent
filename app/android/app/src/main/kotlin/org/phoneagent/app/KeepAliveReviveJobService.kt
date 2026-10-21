package org.phoneagent.app

import android.app.job.JobInfo
import android.app.job.JobParameters
import android.app.job.JobScheduler
import android.app.job.JobService
import android.content.ComponentName
import android.content.Context
import android.util.Log


class KeepAliveReviveJobService : JobService() {
    companion object {
        private const val TAG = "PhoneAgentBoot"
        private const val JOB_ID = 0x5A11
        private const val DELAY_MS = 15_000L


        fun enqueueOneShot(context: Context) {
            try {
                val js = context.getSystemService(JobScheduler::class.java) ?: return
                val job = JobInfo.Builder(
                    JOB_ID,
                    ComponentName(context.applicationContext, KeepAliveReviveJobService::class.java),
                )
                    .setMinimumLatency(DELAY_MS)
                    .setOverrideDeadline(120_000L)
                    .setPersisted(false)
                    .build()
                val r = js.schedule(job)
                Log.i(TAG, "enqueued one-shot revive job (+${DELAY_MS}ms) result=$r")
            } catch (e: Exception) {


                Log.e(TAG, "failed to enqueue revive job", e)
            }
        }
    }

    override fun onStartJob(params: JobParameters?): Boolean {
        val ok = try {
            KeepAliveForegroundService.ensureRunning(applicationContext)
            KeepAliveWatchdog.schedule(applicationContext)
            HeartbeatAlarm.schedule(applicationContext)
            Log.i(TAG, "revive job: ensureRunning ok")
            true
        } catch (e: Exception) {
            Log.w(TAG, "revive job failed, ask system to reschedule", e)
            false
        }


        jobFinished(params, !ok)
        return false
    }

    override fun onStopJob(params: JobParameters?): Boolean = false
}
