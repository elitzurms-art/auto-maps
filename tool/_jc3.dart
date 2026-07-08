import 'dart:io';
import 'package:image/image.dart' as img;
import 'package:auto_maps/services/road_junction_detector.dart';
void main(List<String> a) {
  final im = img.decodeImage(File(a[0]).readAsBytesSync())!;
  final d = RoadJunctionDetector.detectFull(im);
  var j=0,r=0; for(final f in d.features){if(f.kind==MapFeatureKind.junction)j++; if(f.kind==MapFeatureKind.roundabout)r++;}
  stdout.writeln('${a[1]}: img=${im.width}x${im.height} junctions=$j roundabouts=$r roadPts=${d.roadPoints.length}');
}
