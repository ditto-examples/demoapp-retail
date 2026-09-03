import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zava_retail/data/result_coalescer.dart';

void main() {
  group('ResultCoalescer', () {
    test('delivers only the latest within a window', () {
      fakeAsync((async) {
        final delivered = <int>[];
        final coalescer = ResultCoalescer<int>(onChange: delivered.add);
        coalescer.enqueue(1);
        coalescer.enqueue(2);
        coalescer.enqueue(3);
        async.elapse(const Duration(milliseconds: 200));
        expect(delivered, [3]);
        coalescer.dispose();
      });
    });

    test('separate windows deliver separately', () {
      fakeAsync((async) {
        final delivered = <int>[];
        final coalescer = ResultCoalescer<int>(onChange: delivered.add);
        coalescer.enqueue(1);
        async.elapse(const Duration(milliseconds: 150));
        coalescer.enqueue(2);
        async.elapse(const Duration(milliseconds: 150));
        expect(delivered, [1, 2]);
        coalescer.dispose();
      });
    });

    test('dispose drops pending without delivering', () {
      fakeAsync((async) {
        final delivered = <int>[];
        final coalescer = ResultCoalescer<int>(onChange: delivered.add);
        coalescer.enqueue(42);
        coalescer.dispose();
        async.elapse(const Duration(milliseconds: 200));
        expect(delivered, isEmpty);
      });
    });
  });
}
