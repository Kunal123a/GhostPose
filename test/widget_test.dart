import 'package:flutter_test/flutter_test.dart';
import 'package:photo_pose_camera/main.dart';

void main() {
  testWidgets('App renders GhostPose title', (tester) async {
    await tester.pumpWidget(const GhostPoseApp());
    await tester.pump();
    expect(find.text('GhostPose'), findsOneWidget);
  });
}
