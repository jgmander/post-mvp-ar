package com.difrancescogianmarco.arcore_flutter_plugin

import android.app.Activity
import android.app.Application
import android.content.Context
import android.graphics.BitmapFactory
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.Paint
import android.graphics.Path
import android.graphics.RectF
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
import android.view.ViewGroup
import android.widget.ImageView
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
    private val labelNodeMeta = HashMap<String, MutableList<Pair<Node, Float>>>()

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

                // Billboard + proximity LOD for floating 3D caption cards & building stickers
                val camPos = view.scene.camera.worldPosition
                for ((_, entries) in labelNodeMeta) {
                    for (pair in entries) {
                        val labelNode = pair.first
                        val maxDist = pair.second
                        val parent = labelNode.parent ?: continue
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
                            if (maxDist < 100.0f) {
                                val boost = Math.min(2.25f, Math.max(1.0f, 1.0f + (dist - 8.0f) * 0.042f))
                                labelNode.localScale = Vector3(boost, boost, boost)
                            }
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
                            if (event?.action == MotionEvent.ACTION_UP) {
                                var cur: Node? = hitTestResult.node
                                var resolvedName: String? = null
                                while (cur != null) {
                                    if (!cur.name.isNullOrEmpty()) {
                                        resolvedName = cur.name
                                        break
                                    }
                                    cur = cur.parent as? Node
                                }
                                if (resolvedName != null) {
                                    debugLog(" onNodeTap $resolvedName")
                                    methodChannel.invokeMethod("onNodeTap", resolvedName)
                                }
                            }
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

    private fun wrapSignLines(raw: String, maxLineChars: Int = 16, maxTotalChars: Int = 46): List<String> {
        val collapsed = raw.replace("\n", " ").trim().split(Regex("\\s+")).filter { it.isNotEmpty() }.joinToString(" ")
        if (collapsed.isEmpty()) return emptyList()
        val capped = if (collapsed.length > maxTotalChars) {
            collapsed.substring(0, maxTotalChars - 1).trimEnd() + "…"
        } else {
            collapsed
        }
        if (capped.length <= maxLineChars) return listOf(capped)

        val words = capped.split(" ")
        if (words.size <= 1) {
            val mid = Math.min(maxLineChars, capped.length)
            return listOf(capped.substring(0, mid), capped.substring(mid))
        }
        var line1 = ""
        var splitIdx = 0
        val target = capped.length / 2
        for ((idx, w) in words.withIndex()) {
            val candidate = if (line1.isEmpty()) w else "$line1 $w"
            if (candidate.length <= Math.max(maxLineChars, target + 4) && idx < words.size - 1) {
                line1 = candidate
                splitIdx = idx + 1
            } else {
                if (line1.isEmpty()) {
                    line1 = w
                    splitIdx = 1
                }
                break
            }
        }
        val remainder = words.subList(splitIdx, words.size).joinToString(" ")
        if (remainder.isEmpty()) return listOf(line1)
        val cappedLine2 = if (remainder.length > maxLineChars + 4) {
            remainder.substring(0, maxLineChars + 3).trimEnd() + "…"
        } else {
            remainder
        }
        return listOf(line1, cappedLine2)
    }

    private fun drawPostBrandStamp(
        canvas: Canvas,
        rect: RectF,
        fillColor: Int,
        glyphColor: Int,
        borderColor: Int
    ) {
        val w = rect.width()
        val h = rect.height()
        val ox = rect.left
        val oy = rect.top

        val left = ox + w * 0.12f
        val right = ox + w * 0.88f
        val top = oy + h * 0.08f
        val bottom = oy + h * 0.79f
        val r = w * 0.15f
        val fold = w * 0.24f

        val note = Path().apply {
            moveTo(left + r, top)
            lineTo(right - fold, top)
            lineTo(right, top + fold)
            lineTo(right, bottom - r)
            quadTo(right, bottom, right - r, bottom)
            lineTo(ox + w * 0.60f, bottom)
            lineTo(ox + w * 0.50f, oy + h * 0.95f)
            lineTo(ox + w * 0.40f, bottom)
            lineTo(left + r, bottom)
            quadTo(left, bottom, left, bottom - r)
            lineTo(left, top + r)
            quadTo(left, top, left + r, top)
            close()
        }

        val fillPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
            style = Paint.Style.FILL
            color = fillColor
        }
        canvas.drawPath(note, fillPaint)

        val borderPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
            style = Paint.Style.STROKE
            color = borderColor
            strokeWidth = Math.max(4f, w * 0.055f)
            strokeJoin = Paint.Join.ROUND
        }
        canvas.drawPath(note, borderPaint)

        // Folded top-right sticky-note dog-ear flap
        val flap = Path().apply {
            moveTo(right - fold, top)
            lineTo(right - fold, top + fold * 0.78f)
            quadTo(right - fold, top + fold, right - fold * 0.78f, top + fold)
            lineTo(right, top + fold)
            close()
        }
        val flapPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
            style = Paint.Style.FILL
            color = glyphColor
            alpha = 235
        }
        canvas.drawPath(flap, flapPaint)

        // Bold geometric 'P' monogram
        val stemX = ox + w * 0.36f
        val stemTop = oy + h * 0.27f
        val stemBottom = oy + h * 0.63f
        val bowlMidY = oy + h * 0.46f
        val bowlRadius = (bowlMidY - stemTop) * 0.5f
        val bowlCenterX = (ox + w * 0.57f) - bowlRadius

        val pPath = Path().apply {
            moveTo(stemX, stemBottom)
            lineTo(stemX, stemTop)
            lineTo(bowlCenterX, stemTop)
            arcTo(
                RectF(bowlCenterX - bowlRadius, stemTop, bowlCenterX + bowlRadius, bowlMidY),
                -90f,
                180f,
                false
            )
            lineTo(stemX, bowlMidY)
        }
        val pPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
            style = Paint.Style.STROKE
            color = glyphColor
            strokeWidth = Math.max(6f, w * 0.108f)
            strokeCap = Paint.Cap.ROUND
            strokeJoin = Paint.Join.ROUND
        }
        canvas.drawPath(pPath, pPaint)
    }

    private fun renderSignCardBitmap(
        lines: List<String>,
        isLive24h: Boolean,
        isBuildingSticker: Boolean
    ): Bitmap {
        val textPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
            color = Color.WHITE
            textSize = if (isBuildingSticker) 96f else 86f
            typeface = Typeface.create(Typeface.DEFAULT, Typeface.BOLD)
            isSubpixelText = true
        }
        val fm = textPaint.fontMetrics
        val lineHeight = (fm.descent - fm.ascent) + 12f
        var maxTextWidth = 0f
        for (line in lines) {
            maxTextWidth = Math.max(maxTextWidth, textPaint.measureText(line))
        }
        val totalTextHeight = lineHeight * lines.size - 12f

        val postBlue = Color.parseColor("#1A8CFF")
        val liveAmber = Color.parseColor("#FFB82E")
        val darkSlate = Color.parseColor("#F50B1326")

        val borderInset = 18f
        val badgeTabWidth = if (isBuildingSticker) 224f else 168f
        val hPad = if (isBuildingSticker) 64f else 56f
        val vPad = if (isBuildingSticker) 48f else 40f

        val bmpW = Math.ceil((borderInset * 2f + badgeTabWidth + maxTextWidth + hPad * 2f).toDouble()).toInt()
        val bmpH = Math.max(
            Math.ceil((totalTextHeight + vPad * 2f + borderInset * 2f).toDouble()).toInt(),
            if (isBuildingSticker) 280 else 232
        )

        val bmp = Bitmap.createBitmap(bmpW, bmpH, Bitmap.Config.ARGB_8888)
        val canvas = Canvas(bmp)

        val outerRect = RectF(10f, 10f, bmpW - 10f, bmpH - 10f)
        val cornerRad = if (isBuildingSticker) 52f else Math.min(76f, outerRect.height() * 0.42f)

        // Crisp pure-white die-cut vinyl sticker base
        val whitePaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
            style = Paint.Style.FILL
            color = Color.WHITE
        }
        canvas.drawRoundRect(outerRect, cornerRad, cornerRad, whitePaint)

        val insetPx = if (isBuildingSticker) 17f else 12f
        val innerRect = RectF(
            outerRect.left + insetPx,
            outerRect.top + insetPx,
            outerRect.right - insetPx,
            outerRect.bottom - insetPx
        )
        val innerRad = Math.max(24f, cornerRad - (insetPx * 0.8f))
        val innerPath = Path().apply {
            addRoundRect(innerRect, innerRad, innerRad, Path.Direction.CW)
        }

        val bgPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
            style = Paint.Style.FILL
            color = darkSlate
        }
        canvas.drawPath(innerPath, bgPaint)

        // Clip left signature brand tab inside innerPath
        canvas.save()
        canvas.clipPath(innerPath)
        val tabPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
            style = Paint.Style.FILL
            color = if (isLive24h) liveAmber else postBlue
        }
        val tabRect = RectF(innerRect.left, innerRect.top, innerRect.left + badgeTabWidth, innerRect.bottom)
        canvas.drawRect(tabRect, tabPaint)

        val divPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
            style = Paint.Style.FILL
            color = Color.argb(90, 255, 255, 255)
        }
        canvas.drawRect(tabRect.right - 4f, innerRect.top, tabRect.right, innerRect.bottom, divPaint)
        canvas.restore()

        // Stamp custom trademark-distinct Post Folded-Note 'P' mark
        val stampSide = Math.min(badgeTabWidth * 0.68f, innerRect.height() * 0.66f)
        val stampRect = RectF(
            innerRect.left + (badgeTabWidth - stampSide) / 2f,
            innerRect.top + (innerRect.height() - stampSide) / 2f,
            innerRect.left + (badgeTabWidth + stampSide) / 2f,
            innerRect.top + (innerRect.height() + stampSide) / 2f
        )
        drawPostBrandStamp(
            canvas,
            stampRect,
            if (isLive24h) Color.parseColor("#0B1326") else postBlue,
            Color.WHITE,
            Color.WHITE
        )

        val accentStroke = Paint(Paint.ANTI_ALIAS_FLAG).apply {
            style = Paint.Style.STROKE
            color = if (isLive24h) liveAmber else postBlue
            strokeWidth = 5f
        }
        canvas.drawPath(innerPath, accentStroke)

        // Draw 1-or-2-line bold caption
        val contentLeft = innerRect.left + badgeTabWidth + hPad
        val contentWidth = innerRect.right - hPad - contentLeft
        val startY = innerRect.centerY() - (totalTextHeight / 2f) - fm.ascent
        for ((idx, line) in lines.withIndex()) {
            val lineW = textPaint.measureText(line)
            val x = if (isBuildingSticker) contentLeft else contentLeft + Math.max(0f, (contentWidth - lineW) / 2f)
            val y = startY + idx * lineHeight
            canvas.drawText(line, x, y, textPaint)
        }

        return bmp
    }

    private fun buildSignNodeAndAttach(
        parentNode: Node,
        postName: String,
        displayText: String,
        isLive24h: Boolean,
        isBuildingSticker: Boolean,
        planeHeightMeters: Float,
        localYOffset: Float,
        maxVisibleDist: Float
    ) {
        val lines = wrapSignLines(displayText)
        if (lines.isEmpty()) return
        val bmp = renderSignCardBitmap(lines, isLive24h, isBuildingSticker)
        val aspect = bmp.width.toFloat() / Math.max(1, bmp.height).toFloat()
        val planeWidthMeters = planeHeightMeters * aspect

        // Sceneform default DpToMetersViewSizer uses 250dp = 1.0 meter in 3D space
        val density = activity.resources.displayMetrics.density
        val viewHeightPx = Math.max(40, Math.round(planeHeightMeters * 250f * density))
        val viewWidthPx = Math.max(80, Math.round(planeWidthMeters * 250f * density))

        val imgView = ImageView(activity).apply {
            layoutParams = ViewGroup.LayoutParams(viewWidthPx, viewHeightPx)
            scaleType = ImageView.ScaleType.FIT_XY
            setImageBitmap(bmp)
        }

        ViewRenderable.builder()
            .setView(activity, imgView)
            .build()
            .thenAccept { viewRenderable ->
                viewRenderable.isShadowCaster = false
                viewRenderable.isShadowReceiver = false
                val signRoot = Node()
                signRoot.name = postName
                signRoot.localPosition = Vector3(0f, localYOffset, 0f)

                val faceNode = Node()
                faceNode.name = postName
                faceNode.renderable = viewRenderable
                signRoot.addChild(faceNode)

                // Add subtle 2.6cm white 3D plaque backing on Building Bumper Stickers
                if (isBuildingSticker) {
                    val plaqueColor = com.google.ar.sceneform.rendering.Color(0.98f, 0.98f, 1.0f, 1.0f)
                    MaterialFactory.makeOpaqueWithColor(activity.applicationContext, plaqueColor)
                        .thenAccept { plaqueMat ->
                            val plaque = ShapeFactory.makeCube(
                                Vector3(planeWidthMeters * 0.985f, planeHeightMeters * 0.97f, 0.026f),
                                Vector3(0f, 0f, -0.016f),
                                plaqueMat
                            )
                            plaque.isShadowCaster = false
                            plaque.isShadowReceiver = false
                            val plaqueNode = Node()
                            plaqueNode.name = postName
                            plaqueNode.renderable = plaque
                            signRoot.addChild(plaqueNode)
                        }
                        .exceptionally { null }
                }

                parentNode.addChild(signRoot)
                val list = labelNodeMeta.getOrPut(postName) { mutableListOf() }
                list.add(Pair(signRoot, maxVisibleDist))
            }
            .exceptionally { null }
    }

    private fun attachLabelIfNeeded(parentNode: Node, postName: String, map: HashMap<String, Any>) {
        val isLive24h = (map["isLive24h"] as? Boolean) ?: false
        val shapeMap = map["shape"] as? HashMap<*, *>
        val sphereRadius = ((shapeMap?.get("radius") as? Number)?.toFloat()) ?: 0.6f
        val altAboveGround = ((map["altitude"] as? Number)?.toFloat()) ?: 0f
        val anchorSurface = ((map["anchorSurface"] as? String) ?: "").lowercase()
        val isBalloon = sphereRadius > 1.2f
        val isBuildingSticker = !isBalloon && anchorSurface == "building"

        if (isBalloon) {
            // Crisp pure-white Sky-Contrast Halo Band around Sky Balloons so Electric Post Blue
            // stands out sharply against a bright daytime California blue sky!
            val haloColor = com.google.ar.sceneform.rendering.Color(1.0f, 1.0f, 1.0f, 0.95f)
            MaterialFactory.makeTransparentWithColor(activity.applicationContext, haloColor)
                .thenAccept { haloMat ->
                    val band = ShapeFactory.makeCylinder(
                        sphereRadius * 1.045f,
                        0.15f,
                        Vector3(0f, 0f, 0f),
                        haloMat
                    )
                    band.isShadowCaster = false
                    band.isShadowReceiver = false
                    val bandNode = Node()
                    bandNode.name = postName
                    bandNode.renderable = band
                    bandNode.localRotation = Quaternion.axisAngle(Vector3(1f, 0f, 0.25f).normalized(), 14f)
                    parentNode.addChild(bandNode)
                }
                .exceptionally { null }
        }

        if (isBalloon && altAboveGround >= 5.0f) {
            val tetherHeight = Math.max(2.0f, altAboveGround - sphereRadius - 0.12f)
            val tetherCenter = Vector3(0f, -sphereRadius - tetherHeight / 2.0f, 0f)
            val sheathColor = if (isLive24h) {
                com.google.ar.sceneform.rendering.Color(1.0f, 0.722f, 0.18f, 0.78f)
            } else {
                com.google.ar.sceneform.rendering.Color(0.102f, 0.549f, 1.0f, 0.78f)
            }
            // 1. Outer 3x thicker glowing sheath (0.098m radius = ~20cm light beam)
            MaterialFactory.makeTransparentWithColor(activity.applicationContext, sheathColor)
                .thenAccept { mat ->
                    val cyl = ShapeFactory.makeCylinder(0.098f, tetherHeight, tetherCenter, mat)
                    cyl.isShadowCaster = false
                    cyl.isShadowReceiver = false
                    val tetherNode = Node()
                    tetherNode.name = postName
                    tetherNode.renderable = cyl
                    parentNode.addChild(tetherNode)

                    val groundDisc = ShapeFactory.makeCylinder(
                        0.52f,
                        0.055f,
                        Vector3(0f, -altAboveGround + 0.08f, 0f),
                        mat
                    )
                    groundDisc.isShadowCaster = false
                    groundDisc.isShadowReceiver = false
                    val discNode = Node()
                    discNode.name = postName
                    discNode.renderable = groundDisc
                    parentNode.addChild(discNode)
                }
                .exceptionally { null }

            // 2. Crisp pure-white inner luminous core (0.040m radius)
            val coreColor = com.google.ar.sceneform.rendering.Color(1.0f, 1.0f, 1.0f, 0.94f)
            MaterialFactory.makeTransparentWithColor(activity.applicationContext, coreColor)
                .thenAccept { coreMat ->
                    val coreCyl = ShapeFactory.makeCylinder(0.040f, tetherHeight, tetherCenter, coreMat)
                    coreCyl.isShadowCaster = false
                    coreCyl.isShadowReceiver = false
                    val coreNode = Node()
                    coreNode.name = postName
                    coreNode.renderable = coreCyl
                    parentNode.addChild(coreNode)
                }
                .exceptionally { null }
        }

        val rawInput = (map["label"] as? String)?.trim() ?: ""
        val effectiveText = if (rawInput.isEmpty()) (if (isBuildingSticker) "Post" else "") else rawInput
        if (effectiveText.isEmpty()) return

        val displayText = if (isLive24h) "⚡ $effectiveText" else effectiveText
        val lineCount = wrapSignLines(displayText).size

        if (isBuildingSticker) {
            val stickerHeight = if (lineCount > 1) 0.62f else 0.48f
            buildSignNodeAndAttach(
                parentNode = parentNode,
                postName = postName,
                displayText = displayText,
                isLive24h = isLive24h,
                isBuildingSticker = true,
                planeHeightMeters = stickerHeight,
                localYOffset = 0f,
                maxVisibleDist = 58.0f
            )
        } else {
            val cardHeight = if (isBalloon) {
                if (lineCount > 1) 2.55f else 2.15f
            } else {
                if (lineCount > 1) 0.58f else 0.46f
            }
            val yOffset = sphereRadius + cardHeight * 0.58f + 0.16f
            val maxDist = if (isBalloon) 150.0f else 55.0f
            buildSignNodeAndAttach(
                parentNode = parentNode,
                postName = postName,
                displayText = displayText,
                isLive24h = isLive24h,
                isBuildingSticker = false,
                planeHeightMeters = cardHeight,
                localYOffset = yOffset,
                maxVisibleDist = maxDist
            )

            // Eye-level tether signpost (1.35m above ground) for Sky Balloons when <= 28m away
            if (isBalloon && altAboveGround >= 5.0f) {
                val shortClean = if (effectiveText.length > 26) {
                    effectiveText.substring(0, 25) + "…"
                } else {
                    effectiveText
                }
                buildSignNodeAndAttach(
                    parentNode = parentNode,
                    postName = postName,
                    displayText = "🎈 ↑ $shortClean",
                    isLive24h = isLive24h,
                    isBuildingSticker = false,
                    planeHeightMeters = 0.46f,
                    localYOffset = 1.35f - altAboveGround,
                    maxVisibleDist = 28.0f
                )
            }
        }
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
                            val shapeMap = map["shape"] as? HashMap<*, *>
                            val rad = ((shapeMap?.get("radius") as? Number)?.toFloat()) ?: 0.6f
                            val isBldgSticker = rad <= 1.2f && ((map["anchorSurface"] as? String) ?: "").lowercase() == "building"
                            val anchorNode = AnchorNode(anchor)
                            anchorNode.setParent(arSceneView?.scene)
                            anchorNode.name = flutterArCoreNode.name
                            anchorNode.renderable = if (isBldgSticker) null else renderable
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
                            val shapeMap = map["shape"] as? HashMap<*, *>
                            val rad = ((shapeMap?.get("radius") as? Number)?.toFloat()) ?: 0.6f
                            val isBldgSticker = rad <= 1.2f && ((map["anchorSurface"] as? String) ?: "").lowercase() == "building"
                            val anchorNode = AnchorNode(anchor)
                            anchorNode.setParent(arSceneView?.scene)
                            anchorNode.name = flutterArCoreNode.name
                            anchorNode.renderable = if (isBldgSticker) null else renderable
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
