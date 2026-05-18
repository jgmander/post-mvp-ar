import 'package:firebase_auth/firebase_auth.dart';
void test() {
  FirebaseAuth.instance.fetchSignInMethodsForEmail('test');
}
