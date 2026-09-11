import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/foundation.dart';

class AdminFirebaseOptions {
  static FirebaseOptions get current {
    if (defaultTargetPlatform != TargetPlatform.android) {
      throw UnsupportedError('MediBox Admin šiuo metu skirtas Android.');
    }
    return android;
  }

  static const android = FirebaseOptions(
    apiKey: 'AIzaSyCS4_FhipWdyMl5VtpG-3fKhS-toPpKb6Y',
    appId: '1:281777960665:android:admin-placeholder',
    messagingSenderId: '281777960665',
    projectId: 'medibox-6d80d',
    storageBucket: 'medibox-6d80d.firebasestorage.app',
  );

  static const googleWebClientId =
      '281777960665-b2nigi9i4lfsi6s2gjegvidmnbrhv7mm.apps.googleusercontent.com';
}

