import 'package:pdf/pdf.dart';

import 'display.dart';
import 'models.dart';
import 'theme.dart';

/// Couleurs des documents PDF (factures, bons de commande, relevés, rapports) :
/// la couleur de la boutique, rendue lisible sur papier blanc.
({PdfColor brand, PdfColor soft}) pdfBrandColors(CurrentBusiness b) {
  final p = SamaPalette.light(parseHexColor(b.brandColor) ?? defaultBrand);
  return (brand: PdfColor.fromInt(p.green.toARGB32()), soft: PdfColor.fromInt(p.greenSoft.toARGB32()));
}
