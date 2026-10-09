import unittest
from unittest.mock import patch

from bridge import WDA, WDAError


class TapTests(unittest.TestCase):
    def client(self, failure=None):
        client = WDA("http://127.0.0.1:8100")
        calls = []

        def request(method, path, body=None):
            calls.append((method, path, body))
            if path == "/session":
                return {"sessionId": "test"}
            if path.endswith("/window/size"):
                return {"width": 1024, "height": 1366}
            if failure:
                raise failure
            return None

        client.request = request
        return client, calls

    def test_pixels_map_to_logical_points(self):
        client, calls = self.client()
        result = client.tap(1024, 1366, "pixels", 2048, 2732)
        self.assertEqual((result["x_points"], result["y_points"]), (512, 683))
        self.assertEqual(calls[-1], ("POST", "/session/test/wda/tap", {"x": 512, "y": 683}))

    def test_out_of_bounds_and_rotation_do_not_tap(self):
        for args in [(1024, 0), (-1, 0), (0, 0, "pixels", 2732, 2048)]:
            client, calls = self.client()
            with self.assertRaises(ValueError):
                client.tap(*args)
            self.assertFalse(any(path.endswith("/wda/tap") for _, path, _ in calls))

    def test_invalid_numbers_do_not_contact_device(self):
        for x in (True, float("nan"), float("inf"), "1"):
            client, calls = self.client()
            with self.assertRaises(ValueError):
                client.tap(x, 0)
            self.assertEqual(calls, [])

    def test_ambiguous_failure_never_replays_tap(self):
        client, calls = self.client(WDAError("timeout"))
        with self.assertRaises(WDAError):
            client.tap(0.5, 0.5, "normalized")
        self.assertEqual(sum(path.endswith("/wda/tap") for _, path, _ in calls), 1)

    def test_wda_json_error_is_not_success(self):
        client = WDA("http://127.0.0.1:8100")
        with patch.object(client.opener, "open") as opened:
            opened.return_value.__enter__.return_value.read.return_value = b'{"value":{"error":"invalid session id","message":"expired"}}'
            with self.assertRaisesRegex(WDAError, "expired"):
                client.request("POST", "/session/test/wda/tap", {"x": 1, "y": 1})


if __name__ == "__main__":
    unittest.main()
