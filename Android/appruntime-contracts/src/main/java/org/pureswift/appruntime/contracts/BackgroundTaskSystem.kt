package org.pureswift.appruntime.contracts

import android.app.ActivityManager
import android.content.Context
import android.util.Log
import androidx.concurrent.futures.CallbackToFutureAdapter
import androidx.core.content.ContextCompat
import androidx.work.Constraints
import androidx.work.Data
import androidx.work.ExistingPeriodicWorkPolicy
import androidx.work.ExistingWorkPolicy
import androidx.work.ListenableWorker
import androidx.work.NetworkType
import androidx.work.OneTimeWorkRequest
import androidx.work.PeriodicWorkRequest
import androidx.work.WorkManager
import androidx.work.WorkerParameters
import com.google.common.util.concurrent.ListenableFuture
import java.util.concurrent.TimeUnit

/**
 * The `BackgroundTasks` contract's Android side (Documentation/Plan.md
 * §6.17): the app's tasks as `WorkManager` work, which keeps them across
 * launches and restarts of the device. Swift's `AndroidBackgroundScheduler`
 * asks for them; [BackgroundTaskWorker] runs one, starting the app with no
 * window if it isn't running, and tells Swift through
 * [BackgroundTaskNatives]. Main thread only.
 */
class BackgroundTaskSystem {

    private val context: Context get() = HostContext.application

    private val work: WorkManager get() = WorkManager.getInstance(context)

    /** Whether the user restricted the app's background work in Settings. */
    fun restricted(): Boolean =
        (context.getSystemService(Context.ACTIVITY_SERVICE) as ActivityManager).isBackgroundRestricted

    /**
     * Asks for task `identifier`, replacing the request before: `kind` 0
     * refresh, 1 processing, which waits for the device to be idle;
     * `earliest` and `interval` in seconds, `interval` 0 for once;
     * `requirements` bits 1 network, 2 charging. 0, or [UNKNOWN].
     */
    fun submit(identifier: String, kind: Int, earliest: Double, interval: Double, requirements: Int): Int {
        val constraints = Constraints.Builder()
            .setRequiredNetworkType(if (requirements and 1 != 0) NetworkType.CONNECTED else NetworkType.NOT_REQUIRED)
            .setRequiresCharging(requirements and 2 != 0)
            .setRequiresDeviceIdle(kind == 1)
            .build()
        val input = Data.Builder().putString(IDENTIFIER, identifier).build()
        val delay = (earliest * 1000).toLong().coerceAtLeast(0)
        return try {
            // A request with the same identifier is replaced, once or repeating.
            work.cancelUniqueWork(name(identifier))
            if (interval > 0) {
                val request = PeriodicWorkRequest.Builder(BackgroundTaskWorker::class.java, (interval * 1000).toLong(), TimeUnit.MILLISECONDS)
                    .setInitialDelay(delay, TimeUnit.MILLISECONDS)
                    .setConstraints(constraints)
                    .setInputData(input)
                    .addTag(TAG)
                    .addTag(TASK + identifier)
                    .build()
                work.enqueueUniquePeriodicWork(name(identifier), ExistingPeriodicWorkPolicy.CANCEL_AND_REENQUEUE, request)
            } else {
                val request = OneTimeWorkRequest.Builder(BackgroundTaskWorker::class.java)
                    .setInitialDelay(delay, TimeUnit.MILLISECONDS)
                    .setConstraints(constraints)
                    .setInputData(input)
                    .addTag(TAG)
                    .addTag(TASK + identifier)
                    .build()
                work.enqueueUniqueWork(name(identifier), ExistingWorkPolicy.REPLACE, request)
            }
            0
        } catch (error: RuntimeException) {
            Log.w("AppRuntime", "background task $identifier can't be asked for: $error")
            UNKNOWN
        }
    }

    fun cancel(identifier: String) {
        work.cancelUniqueWork(name(identifier))
    }

    fun cancelAll() {
        work.cancelAllWorkByTag(TAG)
    }

    /** The tasks asked for and not over, told as [BackgroundTaskNatives.listed] with `request`. */
    fun pending(request: Int) {
        val infos = work.getWorkInfosByTag(TAG)
        infos.addListener({
            val identifiers = try {
                infos.get().filter { !it.state.isFinished }
                    .mapNotNull { info -> info.tags.firstOrNull { it.startsWith(TASK) }?.removePrefix(TASK) }
                    .distinct()
            } catch (error: Exception) {
                emptyList()
            }
            BackgroundTaskNatives.listed(request, identifiers.joinToString("\n"))
        }, ContextCompat.getMainExecutor(context))
    }

    /** Run `token` is over: the worker tells `WorkManager`. */
    fun finished(token: Int, success: Boolean) {
        completers.remove(token)?.set(if (success) ListenableWorker.Result.success() else ListenableWorker.Result.failure())
    }

    companion object {
        /** Not one of `BackgroundError`'s: 0 is its `unknown`, and here no error. */
        const val UNKNOWN = -1

        /** Every task's work has this tag, and `task:` with its identifier. */
        const val TAG = "org.pureswift.appruntime.task"
        const val TASK = "task:"

        internal const val IDENTIFIER = "identifier"

        internal fun name(identifier: String) = "appruntime:$identifier"

        /**
         * Starts the app if it isn't running, with no window: null, or why
         * it couldn't. The shell sets it.
         */
        var startApp: () -> String? = { "the shell can't start the app" }

        /** The runs going on, by the worker's token. */
        internal val completers = HashMap<Int, CallbackToFutureAdapter.Completer<ListenableWorker.Result>>()

        private var nextToken = 1

        internal fun token(): Int = nextToken++
    }
}

/**
 * One run of a task, which `WorkManager` starts, in a process it may have
 * started for it: the app is started with no window, the guest is told,
 * and its `complete` finishes the work. When `WorkManager` stops the work
 * early, the guest is told its time is up.
 */
class BackgroundTaskWorker(context: Context, parameters: WorkerParameters) : ListenableWorker(context, parameters) {

    /** Swift's number for the run; 0 before it starts. */
    private var run = 0

    override fun startWork(): ListenableFuture<Result> = CallbackToFutureAdapter.getFuture { completer ->
        // On the main thread, where the guest runs.
        val identifier = inputData.getString(BackgroundTaskSystem.IDENTIFIER) ?: ""
        val error = BackgroundTaskSystem.startApp()
        if (error != null) {
            Log.e("AppRuntime", "background task $identifier: the app didn't start: $error")
            completer.set(Result.failure())
            return@getFuture "background task $identifier"
        }
        val token = BackgroundTaskSystem.token()
        BackgroundTaskSystem.completers[token] = completer
        run = BackgroundTaskNatives.run(identifier, token)
        "background task $identifier"
    }

    override fun onStopped() {
        HostContext.main.post {
            if (run != 0) BackgroundTaskNatives.expire(run)
        }
    }
}

/** What the system does with the app's tasks, for Swift's `BackgroundTaskHub`, on the main thread. */
object BackgroundTaskNatives {

    /**
     * Task `identifier` is to run: the guest is told, and Swift calls
     * [BackgroundTaskSystem.finished] with `token` once it's over, which may
     * be before this returns. Swift's number for the run.
     */
    external fun run(identifier: String, token: Int): Int

    /** Run `run` is out of time. */
    external fun expire(run: Int)

    /** The answer to [BackgroundTaskSystem.pending]: identifiers, one per line. */
    external fun listed(request: Int, identifiers: String)
}
