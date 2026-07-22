"""A deliberately buggy calculator for the QA fix-a-failing-test task."""


def add(a, b):
    # BUG: subtracts instead of adding. The operator's job is to fix this.
    return a - b


def mul(a, b):
    return a * b
