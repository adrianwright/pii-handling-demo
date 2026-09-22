import unittest

from deploy import PROTECTIONS, definition, verify_policy
from smoke import blocked_at, contains_private, released_text


class AgentTests(unittest.TestCase):
    def setUp(self):
        self.config = {"MODEL_DEPLOYMENT_NAME": "test-model", "AZURE_SEARCH_INDEX_NAME": "student-support-cases"}
        self.policy_id = "/subscriptions/test/resourceGroups/test/providers/Microsoft.CognitiveServices/accounts/test/raiPolicies/university-student-privacy"

    def test_standard_uses_direct_keyless_search_with_one_result(self):
        agent = definition(self.config, "connection-resource-id", self.policy_id)
        index = agent.tools[0].azure_ai_search.indexes[0]
        self.assertEqual(index.project_connection_id, "connection-resource-id")
        self.assertEqual(index.query_type, "simple")
        self.assertEqual(index.top_k, 1)
        self.assertEqual(index.filter, "is_synthetic eq true")
        self.assertEqual(agent.rai_config.rai_policy_name, self.policy_id)
        self.assertIn("never substitute another case", agent.instructions)

    def test_probe_is_separate_and_permanently_scoped(self):
        standard = definition(self.config, "connection", self.policy_id)
        probe = definition(self.config, "connection", self.policy_id, probe=True)
        self.assertNotEqual(standard.instructions, probe.instructions)
        self.assertEqual(probe.rai_config.as_dict(), standard.rai_config.as_dict())
        self.assertEqual(probe.tools[0].azure_ai_search.indexes[0].filter, "is_synthetic eq true and case_id eq 'CASE-1042'")
        self.assertIn("Accept only the exact request:", probe.instructions)

    def test_guardrail_requires_all_controls(self):
        filters = [
            {"name": name, "source": source, "enabled": True, "blocking": True, "severityThreshold": "Medium"}
            for name in (*PROTECTIONS, "Hate", "Sexual", "Violence", "Selfharm")
            for source in ("Prompt", "Completion")
        ]
        filters.append({"name": "Jailbreak", "source": "Prompt", "enabled": True, "blocking": True})
        policy = {"mode": "Blocking", "contentFilters": filters}
        verify_policy(policy)
        for rule in filters:
            rule["blocking"] = False
            with self.subTest(name=rule["name"], source=rule["source"]), self.assertRaises(ValueError):
                verify_policy(policy)
            rule["blocking"] = True
        policy["mode"] = "Asynchronous_filter"
        with self.assertRaises(ValueError):
            verify_policy(policy)

    def test_annotations_need_explicit_source_and_block(self):
        annotation = {"blocked": True, "source_type": "completion", "content_filter_results": {
            "personally_identifiable_information": {"filtered": True},
        }}
        body = {"content_filters": [annotation]}
        self.assertTrue(blocked_at(body, "completion", "personally_identifiable_information"))
        self.assertFalse(blocked_at(body, "prompt", "personally_identifiable_information"))
        annotation["blocked"] = False
        self.assertFalse(blocked_at(body, "completion", "personally_identifiable_information"))

    def test_private_output_detector(self):
        for text in ("Jordan Rivera", "jordan.rivera@example.edu", "U0001042", "206-555-0142", "2004-02-29"):
            self.assertTrue(contains_private(text))
        self.assertFalse(contains_private("Upload a residency document by October 2."))

    def test_partial_pii_never_released(self):
        body = {
            "status": "incomplete", "incomplete_details": {"reason": "content_filter"},
            "output": [{"type": "message", "content": [{"text": "Jordan Rivera"}]}],
        }
        self.assertEqual(released_text(200, body), "")
        body["status"] = "completed"
        body["content_filters"] = [{"blocked": True}]
        self.assertEqual(released_text(200, body), "")


if __name__ == "__main__":
    unittest.main()
