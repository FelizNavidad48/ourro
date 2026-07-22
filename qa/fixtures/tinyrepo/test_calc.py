from calc import add, mul


def test_add():
    assert add(2, 3) == 5


def test_mul():
    assert mul(2, 3) == 6


if __name__ == "__main__":
    test_add()
    test_mul()
    print("ALL TESTS PASSED")
