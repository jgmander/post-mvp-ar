import 'package:vector_math/vector_math_64.dart';

import 'arcore_pose.dart';

class ArCoreHitTestResult {
  late double distance;

  late Vector3 translation;

  late Vector4 rotation;

  late String nodeName;

  late ArCorePose pose;

  String? nodeType;
  double? hitLat;
  double? hitLng;
  double? hitAlt;

  ArCoreHitTestResult.fromMap(Map<dynamic, dynamic> map) {
    this.distance = map['distance'];
    this.pose = ArCorePose.fromMap(map['pose']);
    this.nodeType = map['nodeType'];
    this.hitLat = map['hitLat'];
    this.hitLng = map['hitLng'];
    this.hitAlt = map['hitAlt'];
  }
}
