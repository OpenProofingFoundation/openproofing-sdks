"""The reference app retains its pinned Aura resource without a Liquid build product."""
from pathlib import Path
import unittest
ROOT=Path(__file__).resolve().parents[2]

class ReferenceModelRetirementTests(unittest.TestCase):
    def test_active_host_runs_only_aura_from_persisted_inputs(self):
        host=(ROOT/'reference-apps/ios/Sources/FaceComparisonHost.swift').read_text()
        self.assertIn('AuraFaceComparison(modelURL: url)',host)
        self.assertIn('pipeline.runAura',host)
        for removed in ['LiquidFaceAssessment(', 'LiquidEvidenceAssessment(', 'LiquidFaceModel', 'PromptContract', 'runLiquid', 'assessAfterComparison']:
            self.assertNotIn(removed,host)
        pipeline=(ROOT/'reference-apps/ios/Sources/FaceWorkflowPipeline.swift').read_text()
        self.assertIn('persistence.loadStage',pipeline)
        self.assertIn('persistence.saveStage',pipeline)
        self.assertNotIn('runLiquid',pipeline)

    def test_active_ui_cannot_render_liquid_reports_or_status(self):
        source=(ROOT/'reference-apps/ios/Sources/ApplicationHost.swift').read_text()
        for key in ['comparison.visual.title','comparison.visual.summary','telemetry.liquid.title']:
            self.assertNotIn('"'+key+'"',source)
        self.assertIn('telemetry.aura.title',source)

    def test_capture_and_motion_products_survive_runtime_removal(self):
        package=(ROOT/'biometric/Package.swift').read_text()
        for name in ['BiometricSDK','BiometricCapture','BiometricCapturePreview','BiometricInference','KenshikiMotion','AuraFaceNative','onnxruntime']:
            self.assertIn('"'+name+'"',package)
        self.assertTrue((ROOT/'foundation/motion/Sources/KenshikiMotion/PulseCeremonyMotionWitness.swift').is_file())
        self.assertTrue((ROOT/'scripts/provision_reference_model.py').is_file())
