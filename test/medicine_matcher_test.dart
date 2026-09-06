import 'package:flutter_test/flutter_test.dart';
import 'package:medibox/services/medicine_matcher.dart';
void main(){
 test('finds medicine-like receipt lines',(){
   final r=MedicineMatcher.candidateLines('VAISTINE\nIBUMETIN 400 mg N20\nMAISTAS 2.00');
   expect(r.length,1);
 });
 test('finds expiry yyyy-mm',()=>expect(MedicineMatcher.expiry('EXP 2028-04'),'2028-04'));
 test('finds expiry mm/yyyy',()=>expect(MedicineMatcher.expiry('Tinka 04/2028'),'2028-04'));
}