package com.difrancescogianmarco.arcore_flutter_plugin

import android.app.Activity
import android.app.Application
import android.content.Context
import android.graphics.BitmapFactory
import android.graphics.Color
import android.graphics.Typeface
import android.graphics.drawable.GradientDrawable
import android.os.Bundle
import android.os.Handler
import android.text.TextUtils
import android.util.Log
import android.util.TypedValue
import android.view.GestureDetector
import android.view.Gravity
import android.view.MotionEvent
import android.view.View
import android.widget.TextView
import android.widget.Toast
import com.difrancescogianmarco.arcore_flutter_plugin.flutter_models.FlutterArCoreHitTestResult
import com.difrancescogianmarco.arcore_flutter_plugin.flutter_models.FlutterArCoreNode
import com.difrancescogianmarco.arcore_flutter_plugin.flutter_models.FlutterArCorePose
import com.difrancescogianmarco.arcore_flutter_plugin.models.RotatingNode
import com.difrancescogianmarco.arcore_flutter_plugin.utils.ArCoreUtils
import com.google.ar.core.*
import com.google.ar.core.exceptions.CameraNotAvailableException
import com.google.ar.core.exceptions.UnavailableException
import com.google.ar.core.exceptions.UnavailableUserDeclinedInstallationException
import com.google.ar.sceneform.*
import com.google.ar.sceneform.math.Quaternion
import com.google.ar.sceneform.math.Vector3
import com.google.ar.sceneform.rendering.MaterialFactory
import com.google.ar.sceneform.rendering.ModelRenderable
import com.google.ar.sceneform.rendering.ShapeFactory
import com.google.ar.sceneform.rendering.Texture
import com.google.ar.sceneform.rendering.ViewRenderable
import com.google.ar.sceneform.ux.AugmentedFaceNode
import io.flutter.app.FlutterApplication
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.platform.PlatformView

import android.graphics.Bitmap
import android.os.Environment
import android.view.PixelCopy
import android.os.HandlerThread
import android.content.ContextWrapper
import java.io.FileOutputStream
import java.io.File
import java.io.IOException
import java.time.LocalDateTime
import java.time.format.DateTimeFormatter

class ArCoreView(val activity: Activity, context: Context, messenger: BinaryMessenger, id: Int, private val isAugmentedFaces: Boolean, private val debug: Boolean) : PlatformView, MethodChannel.MethodCallHandler {
    private val methodChannel: MethodChannel = MethodChannel(messenger, "arcore_flutter_plugin_$id")
    //       private val activity: Activity = (context.applicationContext as FlutterApplication).currentActivity
    lateinit var activityLifecycleCallbacks: Application.ActivityLifecycleCallbacks
    private var installRequested: Boolean = false
    private var mUserRequestedInstall = true
    private val TAG: String = ArCoreView::class.java.name
    private var arSceneView: ArSceneView? = null
    private val gestureDetector: GestureDetector
    private val RC_PERMISSIONS = 0x123
    private var sceneUpdateListener: Scene.OnUpdateListener
    private var faceSceneUpdateListener: Scene.OnUpdateListener
    private var lastCenterHitBuilding: Boolean = false
    private var lastCenterSummaryKey: String = ""
    private var latestCenterTarget: HashMap<String, Any>? = null
    private var frameCounter: Int = 0
    private val labelNodeMeta = HashMap<String, Pair<Node, Float>>()

    //AUGMENTEDFACE
    private var faceRegionsRenderable: ModelRenderable? = null
    private var faceMeshTexture: Texture? = null
    private val faceNodeMap = HashMap<AugmentedFace, AugmentedFaceNode>()

    init {
        methodChannel.setMethodCallHandler(this)
        arSceneView = ArSceneView(context)
        // Set up a tap gesture detector.
        gestureDetector = GestureDetector(
                context,
                object : GestureDetector.SimpleOnGestureListener() {
                    override fun onSingleTapUp(e: MotionEvent): Boolean {
                        onSingleTap(e)
                        return true
                    }

                    override fun onDown(e: MotionEvent): Boolean {
                        return true
                    }
                })

        sceneUpdateListener = Scene.OnUpdateListener { frameTime ->

            val frame = arSceneView?.arFrame ?: return@OnUpdateListener

            if (frame.camera.trackingState != TrackingState.TRACKING) {
                return@OnUpdateListener
            }

            arSceneView?.let { view ->
                frameCounter += 1
                if (frameCounter % 10 == 0) {
                    val target = performCenterRaycast(frame, view)
                    if (target != null) {
                        latestCenterTarget = target
                        val surfaceType = target["surfaceType"] as? String ?: "none"
                        val distVal = (target["distance"] as? Double) ?: 0.0
                        val summaryKey = "${surfaceType}_${Math.round(distVal)}"
                        if (summaryKey != lastCenterSummaryKey) {
                            lastCenterSummaryKey = summaryKey
                            lastCenterHitBuilding = (target["isBuilding"] as? Boolean) ?: false
                            activity.runOnUiThread {
                                methodChannel.invokeMethod("onCenterHitBuilding", target)
                            }
                        }
                    }
                }

                // Billboard + proximity LOD for floating 3D caption pills
                val camPos = view.scene.camera.worldPosition
                for ((_, pair) in labelNodeMeta) {
                    val labelNode = pair.first
                    val maxDist = pair.second
                    val parent = labelNode.parent
                    if (parent == null) continue
                    val nodePos = parent.worldPosition
                    val dx = camPos.x - nodePos.x
                    val dy = camPos.y - nodePos.y
                    val dz = camPos.z - nodePos.z
                    val dist = Math.sqrt((dx * dx + dy * dy + dz * dz).toDouble()).toFloat()
                    val shouldShow = dist <= maxDist
                    if (labelNode.isEnabled != shouldShow) {
                        labelNode.isEnabled = shouldShow
                    }
                    if (shouldShow) {
                        val lookVec = Vector3(dx, 0f, dz)
                        if (lookVec.length() > 0.01f) {
                            labelNode.worldRotation = Quaternion.lookRotation(lookVec.normalized(), Vector3.up())
                        }
                    }
                }
            }

            for (plane in frame.getUpdatedTrackables(Plane::class.java)) {
                if (plane.trackingState == TrackingState.TRACKING) {

                    val pose = plane.centerPose
                    val map: HashMap<String, Any> = HashMap<String, Any>()
                    map["type"] = plane.type.ordinal
                    map["centerPose"] = FlutterArCorePose(pose.translation, pose.rotationQuaternion).toHashMap()
                    map["extentX"] = plane.extentX
                    map["extentZ"] = plane.extentZ

                    methodChannel.invokeMethod("onPlaneDetected", map)
                }
            }
        }

        faceSceneUpdateListener = Scene.OnUpdateListener { frameTime ->
            run {
                //                if (faceRegionsRenderable == null || faceMeshTexture == null) {
                if (faceMeshTexture == null) {
                    return@OnUpdateListener
                }

                val faceList = arSceneView?.session?.getAllTrackables(AugmentedFace::class.java)

                faceList?.let {
                    // Make new AugmentedFaceNodes for any new faces.
                    for (face in faceList) {
                        if (!faceNodeMap.containsKey(face)) {
                            val faceNode = AugmentedFaceNode(face)
                            faceNode.setParent(arSceneView?.scene)
                            faceNode.faceRegionsRenderable = faceRegionsRenderable
                            faceNode.faceMeshTexture = faceMeshTexture
                            faceNodeMap[face] = faceNode
                        }
                    }

                    // Remove any AugmentedFaceNodes associated with an AugmentedFace that stopped tracking.
                    val iter = faceNodeMap.iterator()
                    while (iter.hasNext()) {
                        val entry = iter.next()
                        val face = entry.key
                        if (face.trackingState == TrackingState.STOPPED) {
                            val faceNode = entry.value
                            faceNode.setParent(null)
                            iter.remove()
                        }
                    }
                }
            }
        }

        // Lastly request CAMERA permission which is required by ARCore.
        ArCoreUtils.requestCameraPermission(activity, RC_PERMISSIONS)
        setupLifeCycle(context)
    }

    fun debugLog(message: String) {
        Log.i("ARCoreView.kt", message)
    }


    fun loadMesh(textureBytes: ByteArray?) {
        // Load the face regions renderable.
        // This is a skinned model that renders 3D objects mapped to the regions of the augmented face.
        /*ModelRenderable.builder()
                .setSource(activity, Uri.parse("fox_face.sfb"))
                .build()
                .thenAccept { modelRenderable ->
                    faceRegionsRenderable = modelRenderable;
                    modelRenderable.isShadowCaster = false;
                    modelRenderable.isShadowReceiver = false;
                }*/

        // Load the face mesh texture.
        //                .setSource(activity, Uri.parse("fox_face_mesh_texture.png"))
        Texture.builder()
                .setSource(BitmapFactory.decodeByteArray(textureBytes, 0, textureBytes!!.size))
                .build()
                .thenAccept { texture -> faceMeshTexture = texture }
    }


    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "init" -> {
                arScenViewInit(call, result, activity)
            }
            "addArCoreNode" -> {
                debugLog(" addArCoreNode")
                val map = call.arguments as HashMap<String, Any>
                val flutterNode = FlutterArCoreNode(map);
                onAddNode(flutterNode, result)
            }
            "addArCoreNodeWithAnchor" -> {
                debugLog(" addArCoreNode")
                val map = call.arguments as HashMap<String, Any>
                val flutterNode = FlutterArCoreNode(map)
                addNodeWithAnchor(flutterNode, result)
            }
            "primeLandmarks" -> {
                debugLog(" primeLandmarks")
                val map = call.arguments as HashMap<String, Any>
                val placeIds = map["placeIds"] as ArrayList<String>
                // In a production app with Maps API integrated on the native side,
                // this would pre-warm the AR scene caching based on these Place IDs.
                debugLog("Primed AR session with ${placeIds.size} nearby landmarks.")
                result.success(null)
            }
            "removeARCoreNode" -> {
                debugLog(" removeARCoreNode")
                val map = call.arguments as HashMap<String, Any>
                removeNode(map["nodeName"] as String, result)
            }
            "positionChanged" -> {
                debugLog(" positionChanged")

            }
            "rotationChanged" -> {
                debugLog(" rotationChanged")
                updateRotation(call, result)

            }
            "updateMaterials" -> {
                debugLog(" updateMaterials")
                updateMaterials(call, result)

            }
            "takeScreenshot" -> {
                debugLog(" takeScreenshot")
                takeScreenshot(call, result)

            }
            "loadMesh" -> {
                val map = call.arguments as HashMap<String, Any>
                val textureBytes = map["textureBytes"] as ByteArray
                loadMesh(textureBytes)
            }
            "dispose" -> {
                debugLog("Disposing ARCore now")
                dispose()
            }
            "resume" -> {
                debugLog("Resuming ARCore now")
                onResume()
            }
            "getTrackingState" -> {
                debugLog("1/3: Requested tracking state, returning that back to Flutter now")

                val trState = arSceneView?.arFrame?.camera?.trackingState
                debugLog("2/3: Tracking state is " + trState.toString())
                methodChannel.invokeMethod("getTrackingState", trState.toString())
            }
            "resume" -> {
                debugLog("Forcing onResume from Flutter")
                onResume()
                result.success(null)
            }
            "togglePlaneRenderer" -> {
                debugLog(" Toggle planeRenderer visibility" )
                arSceneView!!.planeRenderer.isVisible = !arSceneView!!.planeRenderer.isVisible
                result.success(null)
            }
            "getGeospatialPose" -> {
                debugLog(" getGeospatialPose")
                getGeospatialPose(call, result)
            }
            "raycastCenter" -> {
                val frame = arSceneView?.arFrame
                val view = arSceneView
                if (frame != null && view != null && frame.camera.trackingState == TrackingState.TRACKING) {
                    val fresh = performCenterRaycast(frame, view)
                    if (fresh != null) {
                        latestCenterTarget = fresh
                        result.success(fresh)
                    } else {
                        result.success(latestCenterTarget)
                    }
                } else {
                    result.success(latestCenterTarget)
                }
            }
            "addEarthAnchorNode" -> {
                debugLog(" addEarthAnchorNode")
                val map = call.arguments as HashMap<String, Any>
                addEarthAnchorNode(map, result)
            }
            "resolveAnchorOnRooftopAsync" -> {
                debugLog(" resolveAnchorOnRooftopAsync")
                val map = call.arguments as HashMap<String, Any>
                resolveAnchorOnRooftopAsync(map, result)
            }
            "resolveAnchorOnTerrainAsync" -> {
                debugLog(" resolveAnchorOnTerrainAsync")
                val map = call.arguments as HashMap<String, Any>
                resolveAnchorOnTerrainAsync(map, result)
            }
            else -> {
            }
        }
    }

/*    fun maybeEnableArButton() {
        Log.i(TAG,"maybeEnableArButton" )
        try{
            val availability = ArCoreApk.getInstance().checkAvailability(activity.applicationContext)
            if (availability.isTransient) {
                // Re-query at 5Hz while compatibility is checked in the background.
                Handler().postDelayed({ maybeEnableArButton() }, 200)
            }
            if (availability.isSupported) {
                debugLog("AR SUPPORTED")
            } else { // Unsupported or unknown.
                debugLog("AR NOT SUPPORTED")
            }
        }catch (ex:Exception){
            Log.i(TAG,"maybeEnableArButton ${ex.localizedMessage}" )
        }

    }*/

    private fun setupLifeCycle(context: Context) {
        activityLifecycleCallbacks = object : Application.ActivityLifecycleCallbacks {
            override fun onActivityCreated(activity: Activity, savedInstanceState: Bundle?) {
                debugLog("onActivityCreated")
//                maybeEnableArButton()
            }

            override fun onActivityStarted(activity: Activity) {
                debugLog("onActivityStarted")
            }

            override fun onActivityResumed(activity: Activity) {
                debugLog("onActivityResumed")
                onResume()
            }

            override fun onActivityPaused(activity: Activity) {
                debugLog("onActivityPaused")
                onPause()
            }

            override fun onActivityStopped(activity: Activity) {
                debugLog("onActivityStopped (Just so you know)")
//                onPause()
            }

            override fun onActivitySaveInstanceState(activity: Activity, outState: Bundle) {}

            override fun onActivityDestroyed(activity: Activity) {
                debugLog("onActivityDestroyed (Just so you know)")
//                onDestroy()
//                dispose()
            }
        }

        activity.application.registerActivityLifecycleCallbacks(this.activityLifecycleCallbacks)
    }

    private fun onSingleTap(tap: MotionEvent?) {
        debugLog(" onSingleTap")
        val frame = arSceneView?.arFrame
        if (frame != null) {
            if (tap != null && frame.camera.trackingState == TrackingState.TRACKING) {
                val hitList = frame.hitTest(tap)
                val list = ArrayList<HashMap<String, Any>>()
                for (hit in hitList) {
                    val trackable = hit.trackable
                    var nodeType: String? = null
                    
                    if (trackable is StreetscapeGeometry) {
                        nodeType = trackable.type.name
                        debugLog("AUDIT: Hit StreetscapeGeometry of type: $nodeType")
                    }

                    var hitLat: Double? = null
                    var hitLng: Double? = null
                    var hitAlt: Double? = null
                    val earth = arSceneView?.session?.earth
                    if (earth?.trackingState == TrackingState.TRACKING) {
                        val geospatialPose = earth.getGeospatialPose(hit.hitPose)
                        hitLat = geospatialPose.latitude
                        hitLng = geospatialPose.longitude
                        hitAlt = geospatialPose.altitude
                    }

                    val distance: Float = hit.distance
                    val translation = hit.hitPose.translation
                    val rotation = hit.hitPose.rotationQuaternion
                    val flutterArCoreHitTestResult = FlutterArCoreHitTestResult(distance, translation, rotation, nodeType, hitLat, hitLng, hitAlt)
                    val arguments = flutterArCoreHitTestResult.toHashMap()
                    list.add(arguments)
                }
                methodChannel.invokeMethod("onPlaneTap", list)
            }
        }
    }

    private fun takeScreenshot(call: MethodCall, result: MethodChannel.Result) {
        try {
            // create bitmap screen capture

            // Create a bitmap the size of the scene view.
            val bitmap: Bitmap = Bitmap.createBitmap(arSceneView!!.getWidth(), arSceneView!!.getHeight(),
                    Bitmap.Config.ARGB_8888)

            // Create a handler thread to offload the processing of the image.
            val handlerThread = HandlerThread("PixelCopier")
            handlerThread.start()
            // Make the request to copy.
            // Make the request to copy.
            PixelCopy.request(arSceneView!!, bitmap, { copyResult ->
                if (copyResult === PixelCopy.SUCCESS) {
                    try {
                        saveBitmapToDisk(bitmap)
                    } catch (e: IOException) {
                        e.printStackTrace();
                    }
                }
                handlerThread.quitSafely()
            }, Handler(handlerThread.getLooper()))

        } catch (e: Throwable) {
            // Several error may come out with file handling or DOM
            e.printStackTrace()
        }
        result.success(null)
    }

    @Throws(IOException::class)
    fun saveBitmapToDisk(bitmap: Bitmap):String {

//        val now = LocalDateTime.now()
//        now.format(DateTimeFormatter.ofPattern("M/d/y H:m:ss"))
        val now = "rawScreenshot"
        // android/data/com.hswo.mvc_2021.hswo_mvc_2021_flutter_ar/files/
        // activity.applicationContext.getFilesDir().toString() //doesnt work!!
        // Environment.getExternalStorageDirectory()
        val mPath: String =  Environment.getExternalStorageDirectory().toString() + "/DCIM/" + now + ".jpg"
        val mediaFile = File(mPath)
        debugLog(mediaFile.toString())
        //Log.i("path","fileoutputstream opened")
        //Log.i("path",mPath)
        val fileOutputStream = FileOutputStream(mediaFile)
        bitmap.compress(Bitmap.CompressFormat.JPEG, 100, fileOutputStream)
        fileOutputStream.flush()
        fileOutputStream.close()
//        Log.i("path","fileoutputstream closed")
        return mPath as String
    }

    private fun arScenViewInit(call: MethodCall, result: MethodChannel.Result, context: Context) {
        debugLog("arScenViewInit")
        val enableTapRecognizer: Boolean? = call.argument("enableTapRecognizer")
        if (enableTapRecognizer != null && enableTapRecognizer) {
            arSceneView
                    ?.scene
                    ?.setOnTouchListener { hitTestResult: HitTestResult, event: MotionEvent? ->

                        if (hitTestResult.node != null) {
                            debugLog(" onNodeTap " + hitTestResult.node?.name)
                            debugLog(hitTestResult.node?.localPosition.toString())
                            debugLog(hitTestResult.node?.worldPosition.toString())
                            methodChannel.invokeMethod("onNodeTap", hitTestResult.node?.name)
                            return@setOnTouchListener true
                        }
                        return@setOnTouchListener event?.let { gestureDetector.onTouchEvent(it) } ?: false
                    }
        }
        val enableUpdateListener: Boolean? = call.argument("enableUpdateListener")
        if (enableUpdateListener != null && enableUpdateListener) {
            // Set an update listener on the Scene that will hide the loading message once a Plane is
            // detected.
            arSceneView?.scene?.addOnUpdateListener(sceneUpdateListener)
        }

        val enablePlaneRenderer: Boolean? = call.argument("enablePlaneRenderer")
        if (enablePlaneRenderer != null && !enablePlaneRenderer) {
            debugLog(" The plane renderer (enablePlaneRenderer) is set to " + enablePlaneRenderer.toString())
            arSceneView!!.planeRenderer.isVisible = false
        }
        
        result.success(null)
    }

    fun addNodeWithAnchor(flutterArCoreNode: FlutterArCoreNode, result: MethodChannel.Result) {

        if (arSceneView == null) {
            return
        }

        RenderableCustomFactory.makeRenderable(activity.applicationContext, flutterArCoreNode) { renderable, t ->
            if (t != null) {
                result.error("Make Renderable Error", t.localizedMessage, null)
                return@makeRenderable
            }
            val myAnchor = arSceneView?.session?.createAnchor(Pose(flutterArCoreNode.getPosition(), flutterArCoreNode.getRotation()))
            if (myAnchor != null) {
                val anchorNode = AnchorNode(myAnchor)
                anchorNode.name = flutterArCoreNode.name
                anchorNode.renderable = renderable

                debugLog("addNodeWithAnchor inserted ${anchorNode.name}")
                attachNodeToParent(anchorNode, flutterArCoreNode.parentNodeName)

                for (node in flutterArCoreNode.children) {
                    node.parentNodeName = flutterArCoreNode.name
                    onAddNode(node, null)
                }
            }
            result.success(null)
        }
    }

    fun onAddNode(flutterArCoreNode: FlutterArCoreNode, result: MethodChannel.Result?) {

        debugLog(flutterArCoreNode.toString())
        NodeFactory.makeNode(activity.applicationContext, flutterArCoreNode, debug) { node, throwable ->

            debugLog("onAddNode inserted ${node?.name}")

/*            if (flutterArCoreNode.parentNodeName != null) {
                debugLog(flutterArCoreNode.parentNodeName);
                val parentNode: Node? = arSceneView?.scene?.findByName(flutterArCoreNode.parentNodeName)
                parentNode?.addChild(node)
            } else {
                debugLog("addNodeToSceneWithGeometry: NOT PARENT_NODE_NAME")
                arSceneView?.scene?.addChild(node)
            }*/
            if (node != null) {
                attachNodeToParent(node, flutterArCoreNode.parentNodeName)
                for (n in flutterArCoreNode.children) {
                    n.parentNodeName = flutterArCoreNode.name
                    onAddNode(n, null)
                }
            }

        }
        result?.success(null)
    }

    fun attachNodeToParent(node: Node?, parentNodeName: String?) {
        if (parentNodeName != null) {
            debugLog(parentNodeName);
            val parentNode: Node? = arSceneView?.scene?.findByName(parentNodeName)
            parentNode?.addChild(node)
        } else {
            debugLog("addNodeToSceneWithGeometry: NOT PARENT_NODE_NAME")
            arSceneView?.scene?.addChild(node)
        }
    }

    fun removeNode(name: String, result: MethodChannel.Result) {
        labelNodeMeta.remove(name)
        val node = arSceneView?.scene?.findByName(name)
        if (node != null) {
            arSceneView?.scene?.removeChild(node);
            debugLog("removed ${node.name}")
        }

        result.success(null)
    }

    private fun performCenterRaycast(frame: Frame, view: ArSceneView): HashMap<String, Any>? {
        val earth = view.session?.earth ?: return null
        if (earth.trackingState != TrackingState.TRACKING) return null

        val camPose = frame.camera.pose
        val zAxis = camPose.zAxis
        // Camera looks along -Z in OpenGL / ARCore camera space
        val forwardX = -zAxis[0]
        val forwardY = -zAxis[1]
        val forwardZ = -zAxis[2]

        var closePlaneHit: HitResult? = null
        var ssHit: HitResult? = null
        var ssIsBuilding = false

        try {
            val hitList = frame.hitTest(view.width / 2f, view.height / 2f)
            for (hit in hitList) {
                val trackable = hit.trackable
                val d = hit.distance
                if (trackable is Plane && trackable.trackingState == TrackingState.TRACKING &&
                    trackable.isPoseInPolygon(hit.hitPose) && d in 0.35f..8.0f
                ) {
                    if (closePlaneHit == null || d < closePlaneHit.distance) {
                        closePlaneHit = hit
                    }
                } else if (trackable is StreetscapeGeometry &&
                    trackable.trackingState == TrackingState.TRACKING && d in 0.4f..55.0f
                ) {
                    if (ssHit == null || d < ssHit.distance) {
                        ssHit = hit
                        ssIsBuilding = (trackable.type == StreetscapeGeometry.Type.BUILDING)
                    }
                }
            }
        } catch (_: Exception) {
        }

        var chosenSurface = "none"
        var targetPose: Pose
        var hitDistance = 0f
        var altAboveTerrain = 1.4

        if (closePlaneHit != null && (ssHit == null || closePlaneHit.distance < ssHit.distance - 1.0f)) {
            chosenSurface = "surface"
            hitDistance = closePlaneHit.distance
            val rawPose = closePlaneHit.hitPose
            val pullback = Math.min(0.25f, hitDistance * 0.25f)
            targetPose = Pose.makeTranslation(
                rawPose.tx() - forwardX * pullback,
                rawPose.ty() - forwardY * pullback,
                rawPose.tz() - forwardZ * pullback
            )
            val rawDy = (rawPose.ty() - camPose.ty()).toDouble() + 1.45
            altAboveTerrain = Math.min(Math.max(rawDy, 1.15), 4.5)
        } else if (ssHit != null) {
            chosenSurface = if (ssIsBuilding) "building" else "terrain"
            hitDistance = ssHit.distance
            val rawPose = ssHit.hitPose
            if (ssIsBuilding) {
                val pullback = Math.min(0.7f, hitDistance * 0.35f)
                val adjX = rawPose.tx() - forwardX * pullback
                val adjY = rawPose.ty() - forwardY * pullback
                val adjZ = rawPose.tz() - forwardZ * pullback
                targetPose = Pose.makeTranslation(adjX, adjY, adjZ)
                val rawDy = (rawPose.ty() - camPose.ty()).toDouble() + 1.45
                altAboveTerrain = Math.min(Math.max(rawDy, 1.35), 18.0)
            } else {
                targetPose = rawPose
                altAboveTerrain = 1.35
            }
        } else {
            val horizLen = Math.sqrt((forwardX * forwardX + forwardZ * forwardZ).toDouble()).toFloat()
            val hx = if (horizLen > 0.01f) forwardX / horizLen else 0f
            val hz = if (horizLen > 0.01f) forwardZ / horizLen else -1f
            targetPose = Pose.makeTranslation(
                camPose.tx() + hx * 3.0f,
                camPose.ty(),
                camPose.tz() + hz * 3.0f
            )
            hitDistance = 3.0f
            altAboveTerrain = 1.35
            chosenSurface = "none"
        }

        return try {
            val geoPose = earth.getGeospatialPose(targetPose)
            val out = HashMap<String, Any>()
            out["isBuilding"] = (chosenSurface == "building")
            out["hasTarget"] = (chosenSurface != "none")
            out["surfaceType"] = chosenSurface
            out["distance"] = hitDistance.toDouble()
            out["latitude"] = geoPose.latitude
            out["longitude"] = geoPose.longitude
            out["altitudeAboveTerrain"] = altAboveTerrain
            out
        } catch (_: Exception) {
            val camGeo = earth.cameraGeospatialPose
            val out = HashMap<String, Any>()
            out["isBuilding"] = false
            out["hasTarget"] = false
            out["surfaceType"] = "camera"
            out["distance"] = 0.0
            out["latitude"] = camGeo.latitude
            out["longitude"] = camGeo.longitude
            out["altitudeAboveTerrain"] = 1.35
            out
        }
    }

    private fun attachLabelIfNeeded(parentNode: Node, postName: String, map: HashMap<String, Any>) {
        val isLive24h = (map["isLive24h"] as? Boolean) ?: false
        val shapeMap = map["shape"] as? HashMap<*, *>
        val sphereRadius = ((shapeMap?.get("radius") as? Number)?.toFloat()) ?: 0.6f
        val altAboveGround = ((map["altitude"] as? Number)?.toFloat()) ?: 0f
        val isBalloon = sphereRadius > 1.2f

        if (isBalloon && altAboveGround >= 5.0f) {
            val tetherHeight = Math.max(2.0f, altAboveGround - sphereRadius - 0.15f)
            val sfColor = if (isLive24h) {
                com.google.ar.sceneform.rendering.Color(1.0f, 0.72f, 0.18f, 0.55f)
            } else {
                com.google.ar.sceneform.rendering.Color(0.0f, 0.90f, 1.0f, 0.55f)
            }
            MaterialFactory.makeTransparentWithColor(activity.applicationContext, sfColor)
                .thenAccept { mat ->
                    val cyl = ShapeFactory.makeCylinder(
                        0.032f,
                        tetherHeight,
                        Vector3(0f, -sphereRadius - tetherHeight / 2.0f, 0f),
                        mat
                    )
                    cyl.isShadowCaster = false
                    cyl.isShadowReceiver = false
                    val tetherNode = Node()
                    tetherNode.name = postName
                    tetherNode.renderable = cyl
                    parentNode.addChild(tetherNode)
                }
                .exceptionally { null }
        }

        val rawLabel = (map["label"] as? String)?.trim() ?: return
        if (rawLabel.isEmpty()) return

        val cleanText = if (rawLabel.length > 34) rawLabel.substring(0, 33) + "…" else rawLabel
        val displayText = if (isLive24h) "⚡ $cleanText" else cleanText

        val density = activity.resources.displayMetrics.density
        val textView = TextView(activity).apply {
            text = displayText
            setTextColor(Color.parseColor("#F0F4FF"))
            setTextSize(TypedValue.COMPLEX_UNIT_SP, if (isBalloon) 18f else 13f)
            typeface = Typeface.create(Typeface.DEFAULT, Typeface.BOLD)
            maxLines = 1
            ellipsize = TextUtils.TruncateAt.END
            gravity = Gravity.CENTER
            val hPad = (14 * density).toInt()
            val vPad = (7 * density).toInt()
            setPadding(hPad, vPad, hPad, vPad)
            background = GradientDrawable().apply {
                shape = GradientDrawable.RECTANGLE
                cornerRadius = 999f
                setColor(Color.parseColor("#E00D1220"))
                val strokeColor = if (isLive24h) Color.parseColor("#FFB82E") else Color.parseColor("#00E5FF")
                setStroke((2 * density).toInt(), strokeColor)
            }
        }

        ViewRenderable.builder()
            .setView(activity, textView)
            .build()
            .thenAccept { viewRenderable ->
                viewRenderable.isShadowCaster = false
                viewRenderable.isShadowReceiver = false
                val labelNode = Node()
                labelNode.name = postName
                labelNode.renderable = viewRenderable
                labelNode.localPosition = Vector3(0f, sphereRadius + (if (isBalloon) 1.35f else 0.45f), 0f)
                val scaleFactor = if (isBalloon) 2.4f else 1.0f
                labelNode.localScale = Vector3(scaleFactor, scaleFactor, scaleFactor)
                parentNode.addChild(labelNode)
                val maxVisibleDist = if (isBalloon) 140.0f else 28.0f
                labelNodeMeta[postName] = Pair(labelNode, maxVisibleDist)
            }
            .exceptionally { null }
    }

    private fun getGeospatialPose(call: MethodCall, result: MethodChannel.Result) {
        val earth = arSceneView?.session?.earth
        if (earth?.trackingState == TrackingState.TRACKING) {
            val pose = earth.cameraGeospatialPose
            val map = HashMap<String, Any>()
            map["latitude"] = pose.latitude
            map["longitude"] = pose.longitude
            map["altitude"] = pose.altitude
            map["heading"] = pose.heading
            map["accuracy"] = pose.horizontalAccuracy
            result.success(map)
        } else {
            val failureReason = arSceneView?.arFrame?.camera?.trackingFailureReason?.name ?: "LOCALIZING"
            val sentinel = HashMap<String, Any>()
            sentinel["latitude"] = 0.0
            sentinel["longitude"] = 0.0
            sentinel["altitude"] = 0.0
            sentinel["heading"] = 0.0
            sentinel["accuracy"] = 999.0
            sentinel["trackingFailureReason"] = failureReason
            result.success(sentinel)
        }
    }

    private fun addEarthAnchorNode(map: HashMap<String, Any>, result: MethodChannel.Result) {
        if (arSceneView == null) return
        val earth = arSceneView?.session?.earth
        if (earth?.trackingState != TrackingState.TRACKING) {
            result.error("UNAVAILABLE", "Earth not tracking", null)
            return
        }

        val flutterArCoreNode = FlutterArCoreNode(map)
        val lat = (map["latitude"] as? Number)?.toDouble() ?: 0.0
        val lng = (map["longitude"] as? Number)?.toDouble() ?: 0.0
        val alt = (map["altitude"] as? Number)?.toDouble() ?: 0.0

        RenderableCustomFactory.makeRenderable(activity.applicationContext, flutterArCoreNode) { renderable, t ->
            if (t != null) {
                result.error("Make Renderable Error", t.localizedMessage, null)
                return@makeRenderable
            }
            
            val earthAnchor = earth.createAnchor(lat, lng, alt, 0f, 0f, 0f, 1f)
            if (earthAnchor != null) {
                val anchorNode = AnchorNode(earthAnchor)
                anchorNode.name = flutterArCoreNode.name
                anchorNode.renderable = renderable

                attachNodeToParent(anchorNode, flutterArCoreNode.parentNodeName)
            }
            result.success(null)
        }
    }

    private fun resolveAnchorOnRooftopAsync(map: HashMap<String, Any>, result: MethodChannel.Result) {
        if (arSceneView == null) return
        val earth = arSceneView?.session?.earth
        if (earth?.trackingState != TrackingState.TRACKING) {
            result.error("UNAVAILABLE", "Earth not tracking", null)
            return
        }

        val flutterArCoreNode = FlutterArCoreNode(map)
        val lat = (map["latitude"] as? Number)?.toDouble() ?: 0.0
        val lng = (map["longitude"] as? Number)?.toDouble() ?: 0.0
        val altAboveRoof = (map["altitude"] as? Number)?.toDouble() ?: 0.0

        RenderableCustomFactory.makeRenderable(activity.applicationContext, flutterArCoreNode) { renderable, t ->
            if (t != null) {
                result.error("Make Renderable Error", t.localizedMessage, null)
                return@makeRenderable
            }

            try {
                earth.resolveAnchorOnRooftopAsync(
                    lat, lng, altAboveRoof, 0f, 0f, 0f, 1f
                ) { anchor, state ->
                    if (state.name == "SUCCESS" && anchor != null) {
                        activity.runOnUiThread {
                            val anchorNode = AnchorNode(anchor)
                            anchorNode.setParent(arSceneView?.scene)
                            anchorNode.name = flutterArCoreNode.name
                            anchorNode.renderable = renderable
                            attachLabelIfNeeded(anchorNode, flutterArCoreNode.name, map)
                            attachNodeToParent(anchorNode, flutterArCoreNode.parentNodeName)
                            methodChannel.invokeMethod("onRooftopAnchorResolved", mapOf("name" to flutterArCoreNode.name, "success" to true))
                        }
                    } else {
                        activity.runOnUiThread {
                            methodChannel.invokeMethod("onRooftopAnchorResolved", mapOf("name" to flutterArCoreNode.name, "success" to false, "state" to state.name))
                        }
                    }
                }
                result.success(null)
            } catch (e: Exception) {
                result.error("RooftopAnchor Exception", e.localizedMessage, null)
            }
        }
    }

    private fun resolveAnchorOnTerrainAsync(map: HashMap<String, Any>, result: MethodChannel.Result) {
        if (arSceneView == null) return
        val earth = arSceneView?.session?.earth
        if (earth?.trackingState != TrackingState.TRACKING) {
            result.error("UNAVAILABLE", "Earth not tracking", null)
            return
        }

        val flutterArCoreNode = FlutterArCoreNode(map)
        val lat = (map["latitude"] as? Number)?.toDouble() ?: 0.0
        val lng = (map["longitude"] as? Number)?.toDouble() ?: 0.0
        val altAboveTerrain = (map["altitude"] as? Number)?.toDouble() ?: 0.0

        RenderableCustomFactory.makeRenderable(activity.applicationContext, flutterArCoreNode) { renderable, t ->
            if (t != null) {
                result.error("Make Renderable Error", t.localizedMessage, null)
                return@makeRenderable
            }

            try {
                earth.resolveAnchorOnTerrainAsync(
                    lat, lng, altAboveTerrain, 0f, 0f, 0f, 1f
                ) { anchor, state ->
                    if (state.name == "SUCCESS" && anchor != null) {
                        activity.runOnUiThread {
                            val anchorNode = AnchorNode(anchor)
                            anchorNode.setParent(arSceneView?.scene)
                            anchorNode.name = flutterArCoreNode.name
                            anchorNode.renderable = renderable
                            attachLabelIfNeeded(anchorNode, flutterArCoreNode.name, map)
                            attachNodeToParent(anchorNode, flutterArCoreNode.parentNodeName)
                            methodChannel.invokeMethod("onTerrainAnchorResolved", mapOf("name" to flutterArCoreNode.name, "success" to true, "state" to state.name))
                        }
                    } else {
                        activity.runOnUiThread {
                            methodChannel.invokeMethod("onTerrainAnchorResolved", mapOf("name" to flutterArCoreNode.name, "success" to false, "state" to state.name))
                        }
                    }
                }
                result.success(null)
            } catch (e: Exception) {
                result.error("TerrainAnchor Exception", e.localizedMessage, null)
            }
        }
    }
    fun updateRotation(call: MethodCall, result: MethodChannel.Result) {
        val name = call.argument<String>("name")
        val node = arSceneView?.scene?.findByName(name) as RotatingNode
        debugLog("rotating node:  $node")
        val degreesPerSecond = call.argument<Double?>("degreesPerSecond")
        debugLog("rotating value:  $degreesPerSecond")
        if (degreesPerSecond != null) {
            debugLog("rotating value:  ${node.degreesPerSecond}")
            node.degreesPerSecond = degreesPerSecond.toFloat()
        }
        result.success(null)
    }

    fun updateMaterials(call: MethodCall, result: MethodChannel.Result) {
        val name = call.argument<String>("name")
        val materials = call.argument<ArrayList<HashMap<String, *>>>("materials")!!
        val node = arSceneView?.scene?.findByName(name)
        val oldMaterial = node?.renderable?.material?.makeCopy()
        if (oldMaterial != null) {
            val material = MaterialCustomFactory.updateMaterial(oldMaterial, materials[0])
            node.renderable?.material = material
        }
        result.success(null)
    }

    override fun getView(): View {
        return arSceneView ?: View(activity)
    }

    override fun dispose() {
        if (arSceneView != null) {
            onPause()
            onDestroy()
        }
    }

    fun onResume() {
        debugLog("onResume()")

        if (arSceneView == null) {
            debugLog("AUDIT: arSceneView is null inside onResume, returning early.")
            return
        }

        // request camera permission if not already requested
        if (!ArCoreUtils.hasCameraPermission(activity)) {
            debugLog("AUDIT: hasCameraPermission returned false. Bypassing check for Flutter release build.")
            // ArCoreUtils.requestCameraPermission(activity, RC_PERMISSIONS)
        }

        if (arSceneView?.session == null) {
            debugLog("session is null")
            try {
                val session = ArCoreUtils.createArSession(activity, mUserRequestedInstall, isAugmentedFaces)
                if (session == null) {
                    // Ensures next invocation of requestInstall() will either return
                    // INSTALLED or throw an exception.
                    mUserRequestedInstall = false
                    return
                } else {
                    val config = Config(session)
                    if (isAugmentedFaces) {
                        config.augmentedFaceMode = Config.AugmentedFaceMode.MESH3D
                    }
                    config.updateMode = Config.UpdateMode.LATEST_CAMERA_IMAGE
                    config.focusMode = Config.FocusMode.AUTO;
                    config.planeFindingMode = Config.PlaneFindingMode.HORIZONTAL_AND_VERTICAL;
                    try {
                        debugLog("AUDIT: Attempting to forcibly enable Geospatial Mode.")
                        config.geospatialMode = Config.GeospatialMode.ENABLED
                        config.streetscapeGeometryMode = Config.StreetscapeGeometryMode.ENABLED
                        debugLog("AUDIT: Enabled Geospatial and StreetscapeGeometry successfully.")
                    } catch (e: Exception) {
                        debugLog("AUDIT: GeospatialMode CRASH: " + e.localizedMessage)
                    }
                    session.configure(config)
                    arSceneView?.setupSession(session)
                }
            } catch (ex: UnavailableUserDeclinedInstallationException) {
                // Display an appropriate message to the user zand return gracefully.
                Toast.makeText(activity, "TODO: handle exception " + ex.localizedMessage, Toast.LENGTH_LONG)
                        .show();
                return
            } catch (e: UnavailableException) {
                ArCoreUtils.handleSessionException(activity, e)
                return
            }
        }

        try {
            arSceneView?.resume()
            arSceneView?.scene?.camera?.farClipPlane = 500.0f
        } catch (ex: CameraNotAvailableException) {
            ArCoreUtils.displayError(activity, "Unable to get camera", ex)
            activity.finish()
            return
        }

        if (arSceneView?.session != null) {
            //arSceneView!!.planeRenderer.isVisible = false
            debugLog("Searching for surfaces")
        }
    }

    fun onPause() {
        if (arSceneView != null) {
            arSceneView?.pause()
        }
    }

    fun onDestroy() {
      if (arSceneView != null) {
            debugLog("Goodbye ARCore! Destroying the Activity now 7.")

            try {
                labelNodeMeta.clear()
                arSceneView?.scene?.removeOnUpdateListener(sceneUpdateListener)
                arSceneView?.scene?.removeOnUpdateListener(faceSceneUpdateListener)
                debugLog("Goodbye arSceneView.")

                arSceneView?.destroy()
                arSceneView = null

            }catch (e : Exception){
                e.printStackTrace();
           }
        }
    }

    /* private fun tryPlaceNode(tap: MotionEvent?, frame: Frame) {
        if (tap != null && frame.camera.trackingState == TrackingState.TRACKING) {
            for (hit in frame.hitTest(tap)) {
                val trackable = hit.trackable
                if (trackable is Plane && trackable.isPoseInPolygon(hit.hitPose)) {
                    // Create the Anchor.
                    val anchor = hit.createAnchor()
                    val anchorNode = AnchorNode(anchor)
                    anchorNode.setParent(arSceneView?.scene)

                    ModelRenderable.builder()
                            .setSource(activity.applicationContext, Uri.parse("TocoToucan.sfb"))
                            .build()
                            .thenAccept { renderable ->
                                val node = Node()
                                node.renderable = renderable
                                anchorNode.addChild(node)
                            }.exceptionally { throwable ->
                                Log.e(TAG, "Unable to load Renderable.", throwable);
                                return@exceptionally null
                            }
                }
            }
        }

    }*/

    /*    fun updatePosition(call: MethodCall, result: MethodChannel.Result) {
        val name = call.argument<String>("name")
        val node = arSceneView?.scene?.findByName(name)
        node?.localPosition = parseVector3(call.arguments as HashMap<String, Any>)
        result.success(null)
    }*/
}
