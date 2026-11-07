# Image every step of the training pipeline runs in. scikit-learn is pinned to
# the 1.5 line that KServe 0.21's sklearn runtime pins (scikit-learn~=1.5.1):
# a model pickled with another minor version may not load in the server.
# kfp is the executor the KFP launcher runs inside each step; with it baked
# in, the components set install_kfp_package=False and no step needs PyPI.
# HTTP calls to the Model Registry and to the Git server use the standard library.
FROM python:3.12-slim
RUN pip install --no-cache-dir scikit-learn==1.5.2 joblib==1.4.2 kfp==2.18.0
